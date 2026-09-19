# grainops

[![CI](https://github.com/sriharifortitude/grainops/actions/workflows/ci.yml/badge.svg)](https://github.com/sriharifortitude/grainops/actions/workflows/ci.yml)

The deployment of a self-hosted product-analytics stack built from four
of my repositories, pinned by tag, two ways: `docker compose up` for one
host, and a Helm chart for Kubernetes. With the operational pieces a real
deployment needs: a rate limiter in front, metrics and a dashboard, a
data-quality gate, backups, network policy, and a runbook. Both paths
are proven end to end in CI on every push.

```
browser ──> grainview (nginx :8080) ──/api──> gatelimit ──> eventgrain api ──> postgres
                                                              eventgrain worker ──> redis
prometheus ──> gatelimit /metrics ;  grafana ──> prometheus
tablewarden (one-shot) ──> postgres
```

| component | repository | role |
| --- | --- | --- |
| [eventgrain](https://github.com/sriharifortitude/eventgrain) | TypeScript | event ingest, queries, rollups, erasure, retention |
| [grainview](https://github.com/sriharifortitude/grainview) | TypeScript | the dashboard, served by nginx which also fronts `/api` |
| [gatelimit](https://github.com/sriharifortitude/gatelimit) | Go | per-key rate limits, Redis-backed, IETF headers |
| [tablewarden](https://github.com/sriharifortitude/tablewarden) | Python | data-quality checks over the analytics database |

This repository contains no application code. It contains the compose
file, the gatelimit rules, Prometheus and Grafana provisioning, the
tablewarden checks, a smoke test, and the runbook.

## Run it

    cp .env.example .env            # set the two passwords
    make up                         # builds pinned tags from GitHub and starts everything
    make project NAME="My product" TZ=Europe/Berlin
    open http://localhost:8080      # paste the key; Grafana is on :3000

## Prove it

    make smoke

`scripts/smoke.sh` brings the stack up from scratch, creates a project,
ingests 300 events through the public port, queries them, waits for the
worker to fold them into rollups, fires 400 concurrent requests to show
the rate limit refusing some, checks the metrics reached Prometheus,
runs the data-quality gate, and tears everything down. CI runs it on
every push; the last run's output is in the Actions tab.

    == rate limit: 400 rapid ingest requests against burst 200 must include 429s
    status counts: {"202":228,"429":172}
    == data-quality gate
    10 checks: 10 passed, 0 failed, 0 errored
    SMOKE OK

## Kubernetes

    helm install analytics helm/grainops -n analytics --create-namespace       --set secrets.postgresPassword=... # evaluation; see values.yaml for production secrets

The chart deploys eventgrain (API + worker), grainview and gatelimit as
rootless, read-only containers, with an optional in-cluster Postgres
StatefulSet and Redis for evaluation. What it gets right, because the
kind-based smoke test in CI checks it:

- **Migrations run as init containers** on every API and worker pod,
  serialised by a Postgres advisory lock, so a rolling upgrade migrates
  before the new pod is ready while old pods keep serving. (A Helm
  pre-install hook cannot do this: hooks run before the release's own
  Secret and Postgres exist. The first version of the chart tried.)
- **A bad rule change cannot take the proxy down.** gatelimit validates
  its config at start; the new pod crash-loops, the rollout stalls, the
  old pods keep serving, and `helm upgrade` reports failure.
- **Default-deny NetworkPolicy** with the tier graph as explicit allows.
  The smoke test confirms the API pod *cannot* reach gatelimit and the
  dashboard can, on a CNI that enforces policy (kind does).
- **Two gatelimit replicas enforce one limit** through Redis: 60 burst
  requests through a port-forward give `200 ×11 / 429 ×49`.
- Secrets by reference (`secrets.existingSecret`) for production; `--set`
  values only for evaluation. Rule changes go in a values file, not
  `--set gatelimit.rules[0]...` — Helm replaces lists wholesale.
- PodDisruptionBudgets, topology spread, resource requests and limits,
  `seccompProfile: RuntimeDefault`, all capabilities dropped.

What it leaves to the cluster: TLS (an Ingress with `ingress.enabled`,
cert-manager for certificates), Prometheus (scrape annotations by
default, a `ServiceMonitor` with `gatelimit.serviceMonitor=true`),
and a production Postgres (`postgres.enabled=false` and `DATABASE_URL`
in your Secret).

## What is deliberately configured

- **Versions are pinned** (`EVENTGRAIN_VERSION=v0.1.1` and so on in
  `.env`) and built from git tags. Upgrading is editing one line and
  `make up`; there are no `latest` tags anywhere.
- **Secrets are in `.env` only.** The compose file references them; the
  gatelimit config names an environment variable for Redis rather than an
  address; the tablewarden config names one for the database DSN.
- **One public port.** Only nginx is exposed on all interfaces. Grafana
  is exposed for convenience and should sit behind SSO; Prometheus is
  loopback-only; Postgres and Redis are not published.
- **Migrations run as a job** the API depends on. If the migration fails,
  the API does not start, and `docker compose logs migrate` says why.
- **The worker has its healthcheck disabled** because it inherits the
  API image's HTTP probe and serves nothing. The smoke test found this.
- **`/api/health` has its own gatelimit rule** keyed by IP, ahead of the
  API-key rules, so a load balancer can probe it. The smoke test found
  this too.
- **Redis is a cache**: no persistence, LRU eviction at 256 MB. Losing it
  resets rate-limit state and BullMQ's schedule, both of which rebuild
  themselves.

## What it does not do

- **No TLS.** Terminate it in front (Caddy, a cloud load balancer) and
  forward to 8080. nginx here sets `X-Forwarded-Proto` from what it sees.
- **No Nomad, no ECS.** Compose for one host, Helm for Kubernetes; the
  decisions (pinning, secrets by reference, the health rule, migrations
  before readiness) are the same in both and would carry to a third.
- **No alerting rules.** The Grafana dashboard shows denied share, store
  errors and decision latency; turning those into Alertmanager rules is
  a deployment's call about thresholds.
- **Compose builds from source; Helm pulls from ghcr.io.** Every
  application publishes an image on tag; compose keeps `pull_policy:
  build` so `make up` works offline from a checkout of each repository.
- **The dashboard has no auth.** grainview holds an API key per browser
  tab; anyone who can reach port 8080 can use a key they possess. That is
  the same trust boundary as the API itself.

## Licence

MIT for this repository. The applications carry their own licences
(eventgrain and grainview: BSL 1.1; gatelimit and tablewarden: MIT).
