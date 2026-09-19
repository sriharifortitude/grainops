.PHONY: up down logs check smoke project backup

# Bring the stack up, building pinned application versions from their repositories.
up:
	docker compose up -d --build

down:
	docker compose down

# Everything, including data. Irreversible.
destroy:
	docker compose down -v

logs:
	docker compose logs -f --tail 100 eventgrain eventgrain-worker gatelimit grainview

# Create a project and print its API key once. Usage: make project NAME="My product" TZ=Europe/Berlin
project:
	docker compose run --rm -T eventgrain node dist/cli/main.js project create "$(NAME)" --tz "$(TZ)"

# Data-quality gate over the analytics database; JUnit in reports/.
check:
	docker compose --profile check run --rm tablewarden

# Full end-to-end proof, then tear down (KEEP=1 to leave it running).
smoke:
	bash scripts/smoke.sh

# Logical backup of the analytics database to backups/<timestamp>.sql.gz.
backup:
	mkdir -p backups
	docker compose exec -T postgres pg_dump -U eventgrain eventgrain | gzip > backups/eventgrain-$$(date +%Y%m%d-%H%M%S).sql.gz
	ls -la backups | tail -1
