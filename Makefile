# Sports Betting AI — developer workflow entry points.
#
# Every target is idempotent and safe to run from a clean checkout.
# The Rails app lives in ./backend and runs through Docker Compose so that
# the host Ruby version is never a source of drift.

COMPOSE := docker compose --profile application
BACKEND_IMAGE := sports-betting-ai-backend:dev

.PHONY: help infra-up infra-test backend-build backend-test backend-shell backend-migrate up down logs clean

help:
	@echo "Targets:"
	@echo "  make infra-up        Start postgres, redis and ml"
	@echo "  make infra-test      Run infrastructure configuration tests"
	@echo "  make backend-build   Build the Rails backend image"
	@echo "  make backend-test    Run the RSpec suite against the test database"
	@echo "  make backend-migrate Apply pending migrations in development"
	@echo "  make backend-shell   Open a shell inside a one-off backend container"
	@echo "  make up              Start the full application stack (web + sidekiq)"
	@echo "  make down            Stop all containers"
	@echo "  make logs            Tail logs for web and sidekiq"

infra-up:
	$(COMPOSE) up -d postgres redis ml

infra-test:
	bash scripts/test-infrastructure.sh

backend-build:
	docker build -t $(BACKEND_IMAGE) ./backend

# Runs against the already-running postgres service on the Compose network.
#
# Both data mounts are required, and mirror the `web`/`sidekiq` services in
# docker-compose.yml. The import specs read real CSVs from /data/fixtures, which
# is the repository's data directory mounted at /data. Omitting it makes 21
# import/job/command examples fail with "file not found", which looks like a
# code regression rather than a missing mount.
backend-test:
	docker run --rm --network sports-betting-ai_default \
		-e RAILS_ENV=test \
		-e DATABASE_HOST=postgres \
		-e DATABASE_PORT=5432 \
		-e POSTGRES_USER=sports_ai \
		-e POSTGRES_PASSWORD=local_dev_only \
		-e POSTGRES_TEST_DB=sports_betting_ai_test \
		-v "$(CURDIR)/backend:/app" \
		-v "$(CURDIR)/data:/data:ro" \
		-w /app \
		$(BACKEND_IMAGE) \
		bash -c 'bundle exec rails db:prepare && bundle exec rspec'

backend-migrate:
	$(COMPOSE) run --rm web bundle exec rails db:migrate

backend-shell:
	$(COMPOSE) run --rm web bash

up:
	$(COMPOSE) up -d --build web sidekiq

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f web sidekiq

clean:
	$(COMPOSE) down -v
