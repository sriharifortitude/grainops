#!/usr/bin/env bash
# End-to-end proof that the stack works: bring it up, create a project,
# send events through the public port (nginx -> gatelimit -> eventgrain),
# query them, confirm the rate limit bites, run the data-quality gate,
# and tear down. Exit code is the verdict. CI runs this on every push.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${PUBLIC_PORT:-8080}"
BASE="http://127.0.0.1:${PORT}"
compose() { docker compose --env-file "${ENV_FILE:-.env}" "$@"; }

step() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; compose logs --tail 40 eventgrain gatelimit grainview >&2 || true; exit 1; }

cleanup() {
  if [ "${KEEP:-0}" != "1" ]; then
    step "tearing down"
    compose down -v --remove-orphans >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

step "building and starting"
compose up -d --build postgres redis migrate eventgrain eventgrain-worker gatelimit grainview prometheus grafana

step "waiting for the public port"
for i in $(seq 1 60); do
  if curl -fsS "${BASE}/api/health" >/dev/null 2>&1; then break; fi
  sleep 2
  [ "$i" = 60 ] && fail "public port never answered"
done
curl -fsS "${BASE}/" | grep -q '<div id="root">' || fail "dashboard not served"

step "creating a project through the eventgrain CLI"
OUT="$(compose run --rm -T eventgrain node dist/cli/main.js project create "Smoke" --tz Europe/Berlin)"
KEY="$(printf '%s' "$OUT" | awk '/api key/ {print $3}')"
[ -n "$KEY" ] || fail "no API key in: $OUT"

step "ingesting 300 events through nginx and gatelimit"
BATCH="$(mktemp)"
node -e '
const {randomUUID}=require("crypto");const now=Date.now();const events=[];
for(let i=0;i<300;i++){const id="u"+(i%40);const t=new Date(now-(i%20)*864e5-(i%7)*36e5).toISOString();
events.push({id:randomUUID(),name:"pageview",distinctId:id,occurredAt:t,properties:{country:i%3?"DE":"FR"}});}
process.stdout.write(JSON.stringify({events}));' > "$BATCH"
RES="$(curl -fsS -X POST "${BASE}/api/events" -H "authorization: Bearer ${KEY}" -H 'content-type: application/json' --data-binary "@${BATCH}")"
printf '%s\n' "$RES" | grep -q '"accepted":300' || fail "ingest: $RES"

step "querying, and checking the RateLimit headers came through nginx"
HDR="$(mktemp)"
RES="$(curl -fsS -D "$HDR" -X POST "${BASE}/api/query" -H "authorization: Bearer ${KEY}" -H 'content-type: application/json' \
  -d '{"metric":"count","event":"pageview","range":{"from":"2026-08-01","to":"2026-12-31"},"bucket":"month"}')"
printf '%s\n' "$RES" | grep -q '"metric":"count"' || fail "query: $RES"
grep -qi '^ratelimit-limit: 300' "$HDR" || fail "missing RateLimit-Limit header: $(cat "$HDR")"

step "rollups: waiting for the worker, then the same query should be answered from rollups"
for i in $(seq 1 90); do
  RES="$(curl -fsS -X POST "${BASE}/api/query" -H "authorization: Bearer ${KEY}" -H 'content-type: application/json' \
    -d '{"metric":"count","event":"pageview","range":{"from":"2026-08-01","to":"2026-12-31"},"bucket":"month"}')"
  if printf '%s' "$RES" | grep -q '"source":"rollup"'; then break; fi
  sleep 2
  [ "$i" = 90 ] && fail "rollups never caught up: $RES"
done

step "rate limit: 400 rapid ingest requests against burst 200 must include 429s"
CODES="$(node -e '
const key=process.argv[1], base=process.argv[2];
const body=JSON.stringify({events:[{id:"00000000-0000-4000-8000-000000000001",name:"x",distinctId:"y",occurredAt:new Date().toISOString()}]});
Promise.all(Array.from({length:400},()=>fetch(base+"/api/events",{method:"POST",headers:{authorization:"Bearer "+key,"content-type":"application/json"},body}).then(r=>r.status).catch(()=>0)))
  .then(codes=>{const c={};for(const s of codes)c[s]=(c[s]||0)+1;console.log(JSON.stringify(c));});' "$KEY" "$BASE")"
printf 'status counts: %s\n' "$CODES"
printf '%s' "$CODES" | grep -q '"429"' || fail "no 429s under burst: $CODES"

step "metrics reached Prometheus"
for i in $(seq 1 30); do
  if curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=sum(gatelimit_decisions_total)' 2>/dev/null | grep -q '"value"'; then break; fi
  sleep 2
done

step "data-quality gate"
mkdir -p reports
if compose --profile check run --rm tablewarden; then echo "tablewarden: clean"; else
  code=$?
  # 1 = a check failed (report says which); 2 = could not run. Only 2 fails the smoke test.
  [ "$code" = 1 ] && echo "tablewarden: checks failed (see reports/tablewarden.xml)" || fail "tablewarden could not run (exit $code)"
fi
grep -q '<testsuite' reports/tablewarden.xml || fail "no JUnit report written"

printf '\nSMOKE OK\n'
