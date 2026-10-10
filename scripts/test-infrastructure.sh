#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

pass() {
  echo "PASS: $1"
}

[[ -f docker-compose.yml ]] ||
  fail "docker-compose.yml must exist"

config="$(docker compose --profile application -f docker-compose.yml config --format json)" ||
  fail "Docker Compose configuration must be valid"

for service in web postgres redis sidekiq ml mobile; do
  echo "$config" | SERVICE="$service" python3 -c '
import json, os, sys
services = json.load(sys.stdin).get("services", {})
sys.exit(0 if os.environ["SERVICE"] in services else 1)
' || fail "Missing Compose service: $service"

  pass "Compose service exists: $service"
done

for service in postgres redis ml; do
  echo "$config" | SERVICE="$service" python3 -c '
import json, os, sys
services = json.load(sys.stdin).get("services", {})
healthcheck = services[os.environ["SERVICE"]].get("healthcheck")
sys.exit(0 if healthcheck and healthcheck.get("test") else 1)
' || fail "Missing health check: $service"

  pass "Health check is configured: $service"
done

pass "Infrastructure configuration tests completed"
