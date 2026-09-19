# Runbook

For whoever is on call for a grainops deployment. Each entry: what you
see, what it means, what to do.

## Start, stop, upgrade

    cp .env.example .env && edit .env       # passwords, ports, versions
    make up                                 # builds pinned versions, waits for health
    make logs
    make down                               # keeps data
    make destroy                            # drops data volumes -- irreversible

To upgrade an application, change its `*_VERSION` in `.env` to the new
tag and `make up`. `migrate` runs before the API starts; a failed
migration stops the API from starting, which is the intended behaviour —
check `docker compose logs migrate`.

## Create a project / rotate a key

    make project NAME="Acme web" TZ=Europe/Amsterdam

prints the project id and an API key **once**. To issue a second key or
replace a leaked one:

    docker compose run --rm -T eventgrain node dist/cli/main.js key create <project-id> "rotated 2026-09"
    docker compose exec postgres psql -U eventgrain -c "update api_keys set revoked_at = now() where id = '<old-key-id>'"

Revocation is immediate: gatelimit does not cache keys, and eventgrain
checks `revoked_at` on every request.

## The dashboard says "The API key was not accepted"

Either the key is revoked (see above) or the browser is talking to the
wrong origin. The dashboard must be served from the same origin as
`/api`; that is what the `grainview` container's nginx does. If a reverse
proxy in front of it rewrites paths, `/api/*` must still reach nginx.

## Clients are getting 429

Expected when a client exceeds its rule in `gatelimit/gatelimit.json`.
The response carries `RateLimit-Remaining` and `Retry-After`; a
well-behaved client backs off. To confirm which rule and how often:

    curl -s localhost:9090/api/v1/query?query='sum by (rule) (rate(gatelimit_decisions_total{outcome="denied"}[5m]))'

or open the **gatelimit** dashboard in Grafana. To change a limit: edit
the JSON, `docker compose restart gatelimit` (about a second of 502s
from nginx while it restarts; there is no hot reload yet).

## Clients are getting 503 "rate limiter unavailable"

Only possible with `on_store_error: "closed"`; this deployment ships with
`"open"`. If you switched it: Redis is down. `docker compose ps redis`,
`docker compose logs redis`. Redis here is a cache (no persistence);
restarting it loses limiter state, which means every client briefly gets
a full bucket. That is acceptable.

## `gatelimit_store_errors_total` is increasing

Redis is unreachable from gatelimit and the `open` policy is in force:
requests flow, limits are enforced per gatelimit instance from memory.
With one instance there is no practical difference. Fix Redis; the
counter stops on its own.

## Queries are slow or say `"source": "raw"` for old dates

The worker recomputes rollups for "dirty" days once a minute. If every
query says `raw`:

    docker compose logs --tail 50 eventgrain-worker
    docker compose exec postgres psql -U eventgrain -c "select count(*), min(marked_at) from rollup_dirty"

A large or old backlog means the worker is down or cannot reach Redis
(BullMQ). `make check` flags this too (`rollups.backlog_small`).

## Erasure request (GDPR Art. 17)

    curl -X DELETE http://<host>:8080/api/persons/<distinct-id> -H "authorization: Bearer <key>"

Deletes the person's raw events, marks their days for rollup
recomputation, and writes an `erasures` row holding only a hash of the
id and the count. Rollups are correct again within a minute. Keep the
response (`eventsDeleted`) as evidence. Backups taken before the request
still contain the data; the retention policy on backups is yours to set.

## Access request (Art. 15)

    curl "http://<host>:8080/api/events/export?from=2020-01-01&to=<today>&distinctId=<id>" -H "authorization: Bearer <key>" > person.csv

Note the 400-day limit per range; split older ranges.

## Retention

`RETENTION_MONTHS` (default 13): the worker drops raw-event partitions
older than this every night at 00:30 UTC. Daily aggregates are kept.
Check what exists:

    docker compose run --rm -T eventgrain node dist/cli/main.js partitions

## Backups

    make backup                              # pg_dump to backups/<timestamp>.sql.gz

Restore into an empty stack:

    make up && docker compose stop eventgrain eventgrain-worker gatelimit
    gunzip -c backups/<file>.sql.gz | docker compose exec -T postgres psql -U eventgrain eventgrain
    docker compose start eventgrain eventgrain-worker gatelimit

Redis and Prometheus data are not backed up: one is a cache, the other
has 15 days of retention and is rebuilt by scraping.

## Data-quality gate

    make check                               # exit 0 clean, 1 a check failed, 2 could not run

Reads `tablewarden/eventgrain.toml`, writes `reports/tablewarden.xml`.
Run it from cron and ship the JUnit file wherever your CI reports go.

## Kubernetes specifics

Everything above applies with `kubectl -n <ns> exec deploy/<release>-eventgrain -- …`
in place of `docker compose run --rm -T eventgrain …`, and
`kubectl -n <ns> exec <release>-postgres-0 -- pg_dump …` for backups of the
in-cluster Postgres. Additionally:

- **Changing gatelimit rules:** put the full `gatelimit.rules` list in a
  values file and `helm upgrade -f`. `--set gatelimit.rules[0].burst=…`
  replaces the whole list with one broken rule; gatelimit refuses to start
  on it, the rollout stalls with the old pods serving, and `helm upgrade`
  fails. `kubectl logs` on the new pod names the missing fields.
- **A stuck rollout** (`helm upgrade` timed out): `kubectl get pods` —
  the crash-looping pod's logs say why; `helm rollback <release>` returns
  to the previous values.
- **Migrations:** every API pod runs them at start under an advisory lock.
  If a migration fails, the new pods never become ready and the old ones
  keep serving; fix forward or `helm rollback`. Migrations must be
  backwards compatible with the version still running (expand, then
  contract in a later release).
- **NetworkPolicy** requires an enforcing CNI. If the smoke test prints
  "this cluster's CNI does not enforce NetworkPolicy", the policies are
  present but decorative; treat the namespace as flat.

## Ports

| host port | service | notes |
| --- | --- | --- |
| 8080 | grainview (nginx) → `/api` → gatelimit → eventgrain | the only port that needs to be public |
| 3000 | Grafana | put it behind SSO or a VPN; admin password in `.env` |
| 9090 | Prometheus | loopback only, no auth |

Postgres and Redis are not published.
