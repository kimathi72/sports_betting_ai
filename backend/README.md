# Sports Betting AI — Backend (Rails API)

Rails 7.1 API-only application serving the versioned HTTP API consumed by the
mobile client and internal tooling.

## Requirements

Everything runs through Docker Compose; no host Ruby installation is required.

- Docker Engine + Docker Compose v2
- The `postgres` and `redis` services from the repository-root stack

## Quick start

```bash
# 1. Copy environment defaults
cp .env.example .env

# 2. Start the infrastructure dependencies
make infra-up

# 3. Build the backend image
make backend-build

# 4. Run the test suite (creates and prepares the test database)
make backend-test

# 5. Start the API and worker
make up
```

The API is then reachable at <http://127.0.0.1:3000>.

## Endpoints

| Method | Path                   | Purpose                                   |
| ------ | ---------------------- | ----------------------------------------- |
| GET    | `/up`                  | Rails framework liveness probe            |
| GET    | `/api/v1/health`       | Versioned API liveness probe              |
| GET    | `/api/v1/ready`        | Versioned API readiness probe (PostgreSQL)|
| GET    | `/api/v1/competitions` | Read-only competition index               |
| GET    | `/api/v1/teams`        | Read-only team index                      |
| GET    | `/api/v1/matches`      | Read-only match index                     |

### Liveness — `GET /api/v1/health`

Answers one question: is the Rails process able to respond? It never touches
the database, Redis or any external provider, so a dependency outage cannot
make a healthy process look dead and trigger an unnecessary restart.

- `200 OK` — `{"status":"ok"}`

### Readiness — `GET /api/v1/ready`

Answers a different question: can this process serve requests that depend on
its required dependencies? PostgreSQL is the only required dependency at this
stage. The endpoint reports only that dependency.

- `200 OK` — `{"status":"ready","checks":{"database":"ok"}}`
- `503 Service Unavailable` —
  `{"status":"not_ready","checks":{"database":"unavailable"}}`

Neither response includes credentials, SQL, connection strings, exception
messages or stack traces. The connectivity question is isolated in
`app/services/database_health_check.rb`, which converts any driver failure into
a typed, safe result.

> **Why a middleware exists:** in development Rails configures
> `config.active_record.migration_error = :page_load`, which inserts
> `ActiveRecord::Migration::CheckPending` into the middleware stack. That
> middleware opens a database connection *before* the request reaches the
> router, so during an outage it turned even the liveness probe into a 500.
> `BypassPendingMigrationsForHealth` is inserted immediately before it and
> answers the two health paths without database access. See
> `config/initializers/health_middleware.rb`.

### Read-only football domain

The canonical football records are exposed through three `GET`-only index
endpoints. Each returns a JSON array of persisted records in a deterministic
order; no create, update or delete routes exist. Ordering and public fields:

| Endpoint               | Ordering                        | Fields |
| ---------------------- | ------------------------------- | ------ |
| `/api/v1/competitions` | `name` asc, `id` tie-breaker    | `id`, `name`, `code`, `country` |
| `/api/v1/teams`        | `name` asc, `id` tie-breaker    | `id`, `name`, `country` |
| `/api/v1/matches`      | `kickoff_at` asc, `id` tie-breaker | `id`, `competition_id`, `season_id`, `home_team_id`, `away_team_id`, `kickoff_at`, `status`, `home_score`, `away_score` |

- `code` and `country` are `null` when the source did not supply them.
- `home_score`/`away_score` are `null` for a fixture that has not completed.
- `kickoff_at` is UTC ISO 8601 (for example `"2024-08-17T15:00:00Z"`).
- Teams deliberately omit `normalized_name`, an internal uniqueness key used for
  provider deduplication rather than client-facing identity.

Example — `GET /api/v1/matches`:

```json
[
  {
    "id": 1,
    "competition_id": 1,
    "season_id": 1,
    "home_team_id": 8,
    "away_team_id": 9,
    "kickoff_at": "2024-08-17T15:00:00Z",
    "status": "completed",
    "home_score": 2,
    "away_score": 1
  }
]
```

## Development workflow

### Running tests

```bash
make backend-test                              # db:prepare + full RSpec suite

# Targeted health specs only
cd backend && docker compose -f ../docker-compose.yml run --rm \
  -e RAILS_ENV=test web bundle exec rspec \
  spec/requests/api/v1/health_spec.rb \
  spec/requests/api/v1/ready_spec.rb \
  spec/services/database_health_check_spec.rb \
  spec/middleware/bypass_pending_migrations_for_health_spec.rb
```

The suite uses `use_transactional_fixtures`, so each example rolls back its own
writes. If the test database is left dirty by an interrupted run:

```bash
docker run --rm --network sports-betting-ai_default \
  -e RAILS_ENV=test -e DATABASE_HOST=postgres -e DATABASE_PORT=5432 \
  -e POSTGRES_USER=sports_ai -e POSTGRES_PASSWORD=local_dev_only \
  -e POSTGRES_TEST_DB=sports_betting_ai_test \
  -v "$PWD/backend:/app" -w /app sports-betting-ai-backend:dev \
  bash -c 'bundle exec rails db:drop db:create db:schema:load'
```

### Opening a shell

```bash
make backend-shell         # one-off container on the Compose network
```

### Migrations

```bash
make backend-migrate
```

## Database configuration

PostgreSQL connections are configured entirely from environment variables, with
safe local defaults declared in `config/database.yml`:

| Variable            | Default                              | Meaning                       |
| ------------------- | ------------------------------------ | ----------------------------- |
| `DATABASE_HOST`     | `postgres`                           | Compose service name          |
| `DATABASE_PORT`     | `5432`                               | Port *inside* the network     |
| `POSTGRES_USER`     | `sports_ai`                          | Role                          |
| `POSTGRES_PASSWORD` | `local_dev_only`                     | Local-only placeholder        |
| `POSTGRES_DB`       | `sports_betting_ai_development`      | Development database          |
| `POSTGRES_TEST_DB`  | `sports_betting_ai_test`             | Isolated test database        |
| `POSTGRES_PORT`     | `5434`                               | Host-side published port      |

**Host-side vs container-side ports.** Inside the Compose network Rails always
connects to `postgres:5432`. The `5434` published port exists only so tools
running *outside* Docker (psql, a GUI client) can reach the same server; `5434`
avoids the PostgreSQL instance that commonly occupies `5432` on the host. Never
point Rails at `localhost:5434` from inside a container — there, `localhost` is
the container itself.

The `test` entry uses a separate database that is dropped and recreated by the
suite, so development data can never be touched by a test run.

## Architecture notes

- **Database host**: containers connect to `postgres:5432` over the Compose
  network. The host port is `5434` (see `POSTGRES_PORT`) to avoid colliding with
  a locally installed PostgreSQL server.
- **Environment variables** are read from the repository-root `.env` file and
  fall back to the defaults declared in `config/database.yml`.
- **Background jobs** run through Sidekiq backed by Redis. The queue adapter is
  `:test` in the test environment so specs never require a live Redis.
- **Startup**: `docker-entrypoint.sh` waits for PostgreSQL readiness, then runs
  `db:prepare` only when `RUN_MIGRATIONS=true`. The `web` service migrates;
  `sidekiq` does not, so the two never race against the schema.

## Pinned dependency note

`connection_pool` is pinned to the `2.x` line. `connection_pool` 3.0 changed the
arity of `pop`, which Sidekiq 7.3.x still calls with one argument; allowing 3.x
crashes the Sidekiq scheduler thread at boot. Revisit this pin once Sidekiq
supports `connection_pool` 3.x.

## Importing a football-data.co.uk CSV

One file is imported at a time, into the canonical `Competition` / `Season` /
`Team` / `Match` schema, in a single transaction. Re-running the same file is
safe: existing matches are reused and reported as *skipped*.

### Required arguments

| Argument | Meaning |
| -------- | ------- |
| `path`   | **Absolute** path to the CSV file. Inside Docker the repository's `data/` directory is mounted at `/data` (read-only). |
| `season` | The canonical season label, e.g. `2024/25`. Supplied by the operator; **never** inferred from the fixture dates. |

Both are validated before anything is imported. A missing file, a relative path
or an absent/malformed season label is refused with a non-zero exit status.

### Running it

```bash
# The committed synthetic fixture, into the development database
docker compose --profile application exec -T web \
  bundle exec rake "import:football_data[/data/fixtures/football_data_premier_league_sample.csv,2024/25]"
```

A successful run prints a summary and exits `0`:

```
imported football_data_premier_league_sample.csv (season 2024/25)
  imported 7 rows: 7 created, 0 updated, 0 skipped, 0 rejected
```

Running it a second time reuses everything and changes nothing:

```
imported football_data_premier_league_sample.csv (season 2024/25)
  imported 7 rows: 0 created, 0 updated, 7 skipped, 0 rejected
```

A failed run prints the row errors that need fixing and exits `1`:

```
import failed: broken.csv (season 2024/25)
  row 2: home team name is missing
```

At most 10 errors are printed; the rest are summarised as a count.

### What a failure means

The whole batch is rolled back. A failed import leaves **no** competitions,
seasons, teams, matches or provider identifiers behind — including any created by
rows that were themselves valid. Fix the reported rows and re-run; nothing is
half-applied.

### Result counters

`Import::Result` reports one outcome per input row, so the numbers always add up:

| Counter | Meaning |
| ------- | ------- |
| `input` | data rows read (header excluded, blank lines dropped) |
| `created` | rows stored as a new match |
| `updated` | rows that changed an existing match (e.g. a scheduled fixture receiving its first result) |
| `skipped` | rows that matched a stored match and changed nothing (a repeat import) |
| `rejected` | rows that failed; always equals `input` on a failed run, because the batch rolled back |
| `processed` | `created + updated + skipped` |

### Data-integrity policy for `FTR`

| Source value | Result |
| ------------ | ------ |
| `H`, `D`, `A` | completed; both scores must be valid non-negative integers |
| `P` | postponed; scores must be absent |
| blank, with no scores | scheduled |
| blank, with any score | **rejected** — a score is never silently discarded |
| anything else | **rejected** — a new code needs an explicit mapping |

Rows with a blank `Div`, team name, kickoff time or date are rejected, as are
two-digit years (a strict `dd/mm/yyyy` date is required).

### Identity rules

Provider identity is stored in `external_identifiers` under the `football_data`
namespace, never matched by display name:

- competition — the provider `Div` code (e.g. `E0`)
- season — `season:<competition_id>:<label>`
- team — the provider team name, normalised with `Team.normalize`
- match — the natural fixture key `DIV|YYYY-MM-DD|HH:MM|home|away`, computed by
  the adapter from parsed values so harmless case/whitespace differences cannot
  create a second identity for one fixture

A stored completed result is never overwritten. An incoming row that disagrees
with it fails the batch.
