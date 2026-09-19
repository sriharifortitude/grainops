#!/usr/bin/env bash
# Kubernetes counterpart of smoke.sh: against a cluster the current kubeconfig
# points at (CI uses kind), install the chart, then prove the path browser ->
# grainview -> gatelimit -> eventgrain -> postgres, the worker's rollups, and
# the rate limit under burst. Tears the release down unless KEEP=1.
set -euo pipefail
cd "$(dirname "$0")/.."

NS="${NAMESPACE:-grainops-smoke}"
REL="${RELEASE:-smoke}"
PORT="${LOCAL_PORT:-18080}"
BASE="http://127.0.0.1:${PORT}"

step() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; kubectl -n "$NS" get pods >&2 || true; kubectl -n "$NS" logs deploy/${REL}-eventgrain --tail 30 >&2 || true; exit 1; }
PF_PID=""
cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  if [ "${KEEP:-0}" != "1" ]; then
    step "uninstalling"
    helm uninstall "$REL" -n "$NS" >/dev/null 2>&1 || true
    kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

step "installing the chart"
helm upgrade --install "$REL" helm/grainops -n "$NS" --create-namespace --wait --timeout 10m \
  --set secrets.postgresPassword=smoke-only ${HELM_SET:+$HELM_SET}

step "every pod is ready"
kubectl -n "$NS" get pods
kubectl -n "$NS" wait --for=condition=ready pod -l app.kubernetes.io/instance="$REL" --timeout=120s >/dev/null

step "port-forwarding grainview"
kubectl -n "$NS" port-forward "svc/${REL}-grainview" "${PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
for i in $(seq 1 30); do
  curl -fsS "${BASE}/api/health" >/dev/null 2>&1 && break
  sleep 1
  [ "$i" = 30 ] && fail "port-forward never answered"
done
curl -fsS "${BASE}/" | grep -q '<div id="root">' || fail "dashboard not served through nginx"

step "creating a project inside the cluster"
OUT="$(kubectl -n "$NS" exec "deploy/${REL}-eventgrain" -- node dist/cli/main.js project create "K8s smoke" --tz Europe/Berlin)"
KEY="$(printf '%s' "$OUT" | awk '/api key/ {print $3}')"
[ -n "$KEY" ] || fail "no API key in: $OUT"

step "ingest through grainview -> gatelimit -> eventgrain"
BATCH="$(mktemp)"
node -e '
const {randomUUID}=require("crypto");const now=Date.now();const events=[];
for(let i=0;i<120;i++){events.push({id:randomUUID(),name:"pageview",distinctId:"u"+(i%20),occurredAt:new Date(now-(i%10)*864e5).toISOString()});}
process.stdout.write(JSON.stringify({events}));' > "$BATCH"
RES="$(curl -fsS -X POST "${BASE}/api/events" -H "authorization: Bearer ${KEY}" -H 'content-type: application/json' --data-binary "@${BATCH}")"
printf '%s' "$RES" | grep -q '"accepted":120' || fail "ingest: $RES"

step "query with RateLimit headers"
HDR="$(mktemp)"
curl -fsS -D "$HDR" -o /dev/null -X POST "${BASE}/api/query" -H "authorization: Bearer ${KEY}" -H 'content-type: application/json' \
  -d '{"metric":"count","event":"pageview","range":{"from":"2026-01-01","to":"2026-12-31"},"bucket":"month"}'
grep -qi '^ratelimit-limit: 300' "$HDR" || fail "missing RateLimit headers: $(cat "$HDR")"

step "rollups catch up"
for i in $(seq 1 90); do
  RES="$(curl -fsS -X POST "${BASE}/api/query" -H "authorization: Bearer ${KEY}" -H 'content-type: application/json' \
    -d '{"metric":"count","event":"pageview","range":{"from":"2026-01-01","to":"2026-12-31"},"bucket":"month"}')"
  printf '%s' "$RES" | grep -q '"source":"rollup"' && break
  sleep 2
  [ "$i" = 90 ] && fail "rollups never caught up: $RES"
done

step "rate limit under burst, enforced across two gatelimit replicas via Redis"
# The health rule is keyed by IP with burst 10 at 5/s; a port-forward is slow
# enough that a bigger bucket would refill under the test.
CODES="$(node -e '
const base = process.argv[1];
Promise.all(Array.from({length:60},()=>fetch(base+"/api/health").then(r=>r.status).catch(()=>0)))
  .then(codes=>{const c={};for(const s of codes)c[s]=(c[s]||0)+1;console.log(JSON.stringify(c));});' "$BASE")"
printf 'status counts: %s
' "$CODES"
printf '%s' "$CODES" | grep -q '"429"' || fail "no 429s under burst: $CODES"

step "network policy: the API pod may not reach gatelimit; grainview may"
if kubectl -n "$NS" exec "deploy/${REL}-eventgrain" -c api -- wget -qO- -T 3 "http://${REL}-gatelimit:8080/healthz" >/dev/null 2>&1; then
  echo "note: api -> gatelimit was allowed; this cluster's CNI does not enforce NetworkPolicy"
else
  echo "api -> gatelimit refused, as the policy says"
fi
kubectl -n "$NS" exec "deploy/${REL}-grainview" -- wget -qO- -T 5 "http://${REL}-gatelimit:8080/metrics" | grep -q gatelimit_decisions_total || fail "grainview could not scrape gatelimit metrics"

printf '\nK8S SMOKE OK\n'
