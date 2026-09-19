# grainops

One `docker compose up` for a self-hosted product-analytics stack built
from four of my repositories, pinned by tag, with the operational pieces
a real deployment needs: a rate limiter in front, metrics and a
dashboard, a data-quality gate, backups, and a runbook.

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
    make up                         # builds pinned tags from GitHub, waits for health
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
- **No multi-host orchestration.** This is one host. The same images and
  configuration translate to Kubernetes manifests or Nomad jobs; the
  interesting decisions (pinning, secrets, the health rule, the worker's
  healthcheck) carry over unchanged.
- **No alerting rules.** The Grafana dashboard shows denied share, store
  errors and decision latency; turning those into Alertmanager rules is
  a deployment's call about thresholds.
- **No image registry.** Images are built on the host from source. A
  registry (the compose file already names `ghcr.io` tags) would make
  `make up` a pull instead of a build.
- **The dashboard has no auth.** grainview holds an API key per browser
  tab; anyone who can reach port 8080 can use a key they possess. That is
  the same trust boundary as the API itself.

## Licence

MIT for this repository. The applications carry their own licences
(eventgrain and grainview: BSL 1.1; gatelimit and tablewarden: MIT).
