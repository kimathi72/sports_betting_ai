#!/bin/bash
set -e

# Deliberate startup procedure:
#  1. Wait until PostgreSQL accepts connections (readiness, not just ordering).
#  2. Run pending migrations exactly once. `db:prepare` is idempotent: it
#     creates the database if absent and applies pending migrations otherwise.
#  3. Hand off to the container's CMD (puma or sidekiq).
#
# Set RUN_MIGRATIONS=false on the sidekiq container so only one process
# performs migrations and web/sidekiq never race each other.

db_host="${DATABASE_HOST:-postgres}"
db_port="${DATABASE_PORT:-5432}"
db_user="${POSTGRES_USER:-sports_ai}"

echo "[entrypoint] waiting for PostgreSQL at ${db_host}:${db_port}..."
for attempt in $(seq 1 30); do
  if pg_isready -h "$db_host" -p "$db_port" -U "$db_user" >/dev/null 2>&1; then
    echo "[entrypoint] PostgreSQL is ready."
    break
  fi
  if [ "$attempt" -eq 30 ]; then
    echo "[entrypoint] ERROR: PostgreSQL did not become ready in time." >&2
    exit 1
  fi
  sleep 2
done

if [ "${RUN_MIGRATIONS:-true}" = "true" ]; then
  echo "[entrypoint] running migrations (db:prepare)..."
  bundle exec rails db:prepare
else
  echo "[entrypoint] RUN_MIGRATIONS=false; skipping migrations."
fi

echo "[entrypoint] executing: $*"
exec "$@"
