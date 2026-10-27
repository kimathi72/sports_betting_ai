# Roadmap

Phased delivery plan for the sports betting AI platform. Each phase is completed
only when its acceptance criteria are verified — implementation alone does not
count as done. Phases are worked strictly in order.

Status legend: ✅ complete · 🚧 in progress · ⬜ not started

| Phase | Scope                                          | Status |
| ----- | ---------------------------------------------- | ------ |
| 0     | Repository and infrastructure verification     | ✅     |
| 1     | Rails API bootstrap and RSpec                  | ✅     |
| 2     | Database connectivity and versioned health API | ✅     |
| 3     | Initial football domain                        | ✅     |
| 4     | Data import foundation                         | ✅     |
| 5     | Asynchronous jobs                              | ⬜     |
| 6     | Historical data pipeline                       | ⬜     |
| 7     | Feature engineering                            | ⬜     |
| 8     | Statistical baseline and ML API                | ⬜     |
| 9     | Supervised learning and evaluation             | ⬜     |
| 10    | Prediction persistence and scheduled inference | ⬜     |
| 11    | Results synchronisation and evaluation         | ⬜     |
| 12    | Mobile application                             | ⬜     |
| 13    | Full integration and CI                        | ⬜     |
| 14    | Operational readiness                          | ⬜     |

## Phase 0 — Repository and infrastructure verification ✅

Compose configuration validated for all six service definitions; PostgreSQL 16,
Redis 7 and the FastAPI ML service running and healthy; `GET /health` verified on
the ML service. Host port `5434` confirmed as required because a host PostgreSQL
instance occupies `5432`.

## Phase 1 — Rails API bootstrap and RSpec ✅

Rails 7.1.6 API-only application in `backend/`, RSpec + FactoryBot configured,
`Team` model with a database-enforced unique index, backend Dockerfile plus a
readiness-aware entrypoint, and real `web`/`sidekiq` Compose services replacing
the bootstrap placeholders.

## Phase 2 — Database connectivity and versioned health API ✅

Liveness (`GET /api/v1/health`) and readiness (`GET /api/v1/ready`) endpoints with
tested JSON contracts, an isolated `DatabaseHealthCheck` service, environment
based database configuration, and a regression guard ensuring liveness stays
independent of PostgreSQL availability even when Rails would check pending
migrations first.

## Phase 3 — Initial football domain ✅

Five canonical entities, added incrementally with model specs first, migrations,
real foreign keys, unique indexes and PostgreSQL check constraints.

### Entities

- **Competition** — top of the hierarchy. `name` is the required, unique
  identity. `code` (e.g. "EPL") is optional and unique only when present
  (partial unique index), because not every source supplies one and a code is
  not a stable external identifier. `country` is optional.
- **Season** — a period within a competition. `name` is the platform's own label
  (e.g. "2024/25"), unique within its competition; providers' inconsistent label
  formats are mapped through ExternalIdentifier rather than stored here.
  `start_date` and `end_date` are optional; when both are present, the start must
  not be after the end.
- **Team** — identified independently of competition or season. `name` stores the
  source display name verbatim; `normalized_name` is a deterministic projection
  (transliterate → downcase → collapse whitespace → trim) and is the unique
  identity. Aliases and fuzzy matching are deliberately out of scope until the
  provider-import phase.
- **Match** — a fixture and, once played, its final result. See the rules below.
- **ExternalIdentifier** — maps a provider's identifier onto a canonical record.
  See the design note below.

### Relationships

- Competition has many seasons and many matches.
- Season belongs to competition and has many matches.
- Team has many `home_matches` and many `away_matches`.
- Match belongs to competition, season, `home_team` and `away_team`.
- ExternalIdentifier maps to exactly one of competition, season, team or match.

Referenced records are protected: competition, season and team deletions are
restricted while matches reference them (`dependent: :restrict_with_error`),
so history is never silently destroyed.

### Match statuses and score rules

Statuses are a closed set — `scheduled`, `postponed`, `cancelled`, `in_progress`,
`completed` — enforced by a check constraint; arbitrary strings are rejected.
Score rules, also enforced by check constraints in addition to model
validations:

- scores are non-negative integers when present;
- home and away scores are either both present or both absent;
- a completed match must carry both scores;
- a match that has not completed is not required to have scores, so postponed and
  cancelled fixtures are representable without inventing a result.

### Database constraints and indexes

- `seasons` — FK to competitions; unique `[competition_id, name]`; check
  `start_date IS NULL OR end_date IS NULL OR start_date <= end_date`.
- `teams` — unique `normalized_name`.
- `competitions` — unique `name`; partial unique `code WHERE code IS NOT NULL`.
- `matches` — FKs to competitions, seasons and both teams; check constraints for
  differing teams, supported status, non-negative scores, paired scores and
  completed-has-scores; indexes on kickoff, status and `[season_id, kickoff_at]`.
- `external_identifiers` — FKs to competitions, seasons, teams and matches; check
  constraint `num_nonnulls(competition_id, season_id, team_id, match_id) = 1`;
  four partial unique indexes on `[provider, external_id]` (one per target type).

### External identifier design and limitations

Explicit nullable foreign keys are used instead of a Rails polymorphic
`*_type`/`*_id` pair. A polymorphic id column cannot carry a database foreign
key, so the referenced row would be unverifiable in PostgreSQL and the type
string could name any class. Here every target is a real FK and the database
additionally requires exactly one target per row, so both referential integrity
and single-target are guaranteed even for writes that bypass ActiveRecord.
Uniqueness is scoped to provider plus entity type, so the same external id may
legitimately appear across providers and across entity types.

Deliberate limitations of this choice:

- adding a new mappable entity type needs a migration (a nullable column and a
  matching partial unique index), not just application code;
- the single-target rule exists in both the model validation and the check
  constraint, so the two must be kept in step.

### Competition/season consistency

A match must not reference a season belonging to a different competition. This is
enforced in the model only (`Match#season_must_belong_to_competition`), not by a
composite foreign key. A database-enforced composite relationship would require
adding `competition_id` to the seasons identity or a composite FK, which was
judged unjustified complexity for this milestone. **Documented limitation:**
writes that bypass ActiveRecord could create a mismatched season/competition
pair.

### Read-only API endpoints

Minimal index endpoints expose the canonical records. All are `GET`-only and
return a JSON array in deterministic order; there are no create, update or delete
routes, by design for this milestone. Each payload contains persisted records
only and never leaks internal implementation fields.

| Method | Path                   | Ordering                                        |
| ------ | ---------------------- | ----------------------------------------------- |
| GET    | `/api/v1/competitions` | `name` ascending, `id` tie-breaker              |
| GET    | `/api/v1/teams`        | `name` ascending, `id` tie-breaker              |
| GET    | `/api/v1/matches`      | `kickoff_at` ascending, `id` tie-breaker        |

Response fields:

- **Competitions** — `id`, `name`, `code`, `country` (`code`/`country` are `null`
  when absent).
- **Teams** — `id`, `name`, `country`. `normalized_name` is deliberately omitted:
  it is an internal uniqueness key for provider deduplication, not client-facing
  identity.
- **Matches** — `id`, `competition_id`, `season_id`, `home_team_id`,
  `away_team_id`, `kickoff_at` (UTC ISO 8601), `status`, `home_score`,
  `away_score` (`home_score`/`away_score` are `null` for a fixture that has not
  completed). `kickoff_at` is `NOT NULL` in the schema, so a null kickoff is not
  representable and no null-ordering policy is required.

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

### Commands

```bash
make backend-test          # full RSpec suite against the test database
docker compose --profile application exec -T web bundle exec rails db:migrate

# Focused request specs for the read-only endpoints
docker run --rm --network sports-betting-ai_default \
  -e RAILS_ENV=test -e DATABASE_HOST=postgres -e DATABASE_PORT=5432 \
  -e POSTGRES_USER=sports_ai -e POSTGRES_PASSWORD=local_dev_only \
  -e POSTGRES_TEST_DB=sports_betting_ai_test \
  -v "$PWD/backend:/app" -w /app sports-betting-ai-backend:dev \
  bash -c 'bundle exec rspec spec/requests/api/v1/{competitions,teams,matches}_spec.rb'
```

Status: ✅ complete — five domain entities, database-enforced integrity and three
read-only index endpoints, verified by live endpoint smoke tests, container health
checks and the full RSpec suite. The exact example count is recorded by the
Phase 4 test run below rather than pinned here, since it grows with every phase.

## Phase 4 — Data import foundation ✅

Imports one football-data.co.uk CSV file into the canonical Phase 3 schema,
transactionally and idempotently. No Sidekiq jobs, no bulk season ingestion, no
provider polling — this milestone is the import *foundation* only.

### Import contract and design

The pipeline is split into single-purpose layers. Provider-specific parsing is
deliberately kept away from domain persistence, so a second provider can be added
later by writing one adapter and reusing the importer unchanged.

| Layer | Class | Responsibility |
| ----- | ----- | -------------- |
| 1. Read | `Import::CsvReader` | Open the file, validate the declared columns exist, return raw rows keyed by the file's own header text. Knows nothing about football. |
| 2. Map | `Import::FootballDataCoUkAdapter` | Turn each raw row into a normalized `Import::MatchRow` (or an error). Knows football-data.co.uk's column names and date format; owns all provider knowledge. |
| 3. Resolve | `Import::ReferenceResolver` | Map provider identifiers to canonical records via `ExternalIdentifier`, returning an `Import::Resolution` outcome (never a raw database exception). |
| 4. Persist | `Import::MatchImporter` | Wrap the whole batch in one transaction, enforce atomicity, detect conflicting results and return an `Import::Result`. |
| — Run | `Import::Command` + `rake import:football_data` | Validate operator arguments, invoke the importer, print a concise report, exit non-zero on failure. |

### Import result contract

`Import::Result` reports exactly one outcome per input row, and the constructor
enforces the arithmetic rather than trusting callers:

| Counter | Meaning |
| ------- | ------- |
| `input` | data rows read (header excluded, blank lines dropped) |
| `created` | rows stored as a new match |
| `updated` | rows that changed an existing match (scheduled/postponed → completed, or a status change) |
| `skipped` | rows that matched a stored match and changed nothing |
| `rejected` | rows that failed validation, resolution or persistence |
| `processed` | derived: `created + updated + skipped` |

`skipped` deliberately replaces the earlier, ambiguous `reused` counter: reusing
a canonical team happens *inside* a row that still created, updated or skipped a
match, so the two concepts never share a counter. Enforced invariants:
`created + updated + skipped + rejected == input`; a successful result has
`rejected == 0`; a failed result has `rejected > 0` and reports no writes, because
the batch was rolled back. Errors are structured hashes carrying the zero-based
`index`, the one-based `row`, and a plain-text `message`.

### Provider and fixture provenance

The source is **football-data.co.uk**, whose Premier League ("E0") season CSVs are
documented at <https://www.football-data.co.uk/englandm.php>. The columns the
adapter relies on (`Div`, `Date`, `Time`, `HomeTeam`, `AwayTeam`, `FTHG`, `FTAG`,
`FTR`) are present in that published schema. The committed fixture
`data/fixtures/football_data_premier_league_sample.csv` is **synthetic**: seven
rows written by hand in the documented column layout, not downloaded historical
data. It is redistributable and lets the parser specs run without network access.
A second synthetic fixture,
`data/fixtures/football_data_premier_league_sample_mixed_statuses.csv`, adds
postponed and scheduled rows so the full status policy is exercised end to end.
Both are committed, hand-written test data; neither is downloaded historical data,
and `data/raw/` remains git-ignored.

### FTR data-integrity policy

`FTR` is the field that decides whether a row asserts a finished result:

| Source value | Outcome |
| ------------ | ------- |
| `H`, `D`, `A` | completed; **both** scores required and must be non-negative integers |
| `P` | postponed; scores must be absent |
| blank, no scores | scheduled |
| blank, with any score | rejected — a score is never silently discarded |
| any other value, including lowercase | rejected; a new code needs an explicit mapping |

A blank `Div`, blank team name, missing/malformed kickoff time or missing date is
rejected. Dates must be strict `dd/mm/yyyy` with a **four-digit year**: Ruby's
`Date.strptime` would otherwise read `16/08/24` as the year 24 AD.

### Identity and mapping policy

The source does not supply stable numeric identifiers for teams or competitions —
it identifies them by `Div` (a competition code) and by team name text. So the
mapping policy is explicit rather than invented:

- **Competition** — resolved by `ExternalIdentifier` on `provider = "football_data"`,
  `external_id = "E0"`; the canonical `name` is seeded on first sight. A competition
  is *never* matched by display name alone.
- **Season** — resolved by `ExternalIdentifier` with the season label the import
  run was configured with (e.g. `"2024/25"`), scoped to the competition. Labels are
  not parsed out of the CSV, because the file carries only per-match dates.
- **Team** — resolved by `ExternalIdentifier` keyed on the provider's team name. On
  first sight the canonical `Team` is created using the existing `Team.normalize`
  policy; thereafter the mapping is reused. Unverified display-name matching is not
  used to merge teams.
- **Match** — resolved by `ExternalIdentifier` on the provider's natural key for the
  fixture (`DIV|YYYY-MM-DD|HH:MM|home|away`), because football-data.co.uk publishes
  no match id. A duplicate mapping means "already imported" and is reused, not
  re-created.

Key normalisation is part of the identity policy, not cosmetic: the date and time
are rendered from parsed values and the names from `Team.normalize`, so
`9:05`/`09:05`, `1/1/2025`/`01/01/2025` and `FULHAM`/`Fulham` cannot create two
identities for one fixture. Team mappings are keyed on the normalised name for the
same reason; the canonical `Team` keeps the first display spelling it saw.

### Idempotency and failure semantics

Every claim below is backed by a database-backed example in
`spec/services/import/match_importer_safety_spec.rb`, which asserts on table
counts and stored rows rather than on the returned result object.

- The whole batch runs in **one database transaction**. A rejected row aborts the
  batch, so a failed import leaves **no** competitions, seasons, teams, matches or
  external identifiers behind — including records created by earlier, valid rows in
  the same batch. Existing records are preserved untouched.
- Re-running the same file is safe: a second run reports every row as `skipped`
  and every table count is unchanged.
- Uniqueness is protected by the database constraints on `external_identifiers` and
  the canonical tables. Because a pre-insert lookup alone would race, a concurrent
  writer that wins either the mapping index or the canonical unique index is
  recovered by re-reading the winning record. Only uniqueness failures are treated
  this way; unrelated database errors are reported, never masked.
- An existing **completed** match whose stored score disagrees with the incoming row
  fails the batch and the stored result is left unchanged. A completed match is also
  never downgraded back to scheduled.
- A scheduled or postponed fixture that receives its first result is **promoted** to
  completed in place, counted as `updated` (not `created`), and keeps its original
  kickoff.

### Manual import command

```bash
docker compose --profile application exec -T web \
  bundle exec rake "import:football_data[/data/fixtures/football_data_premier_league_sample.csv,2024/25]"
```

Both arguments are required and validated before the importer runs. The task
prints a summary plus at most ten row errors, and exits non-zero on failure. See
`backend/README.md` for the full runbook.

### Limitations and deferred work

- Only the football-data.co.uk adapter exists. A second provider needs a new adapter
  class and its own external-identifier namespace; the importer is unchanged.
- Only single-file, single-season imports are supported in this phase. Multi-season
  and multi-league bulk ingestion, scheduling and retries are Phase 5/6 work.
- Season labels are supplied by the operator running the import, not derived from
  the file.
- Encoding support covers UTF-8 with an optional BOM; other encodings are decoded
  as UTF-8 with invalid bytes replaced.
- A provider row that contradicts an already-completed result fails the whole
  batch rather than being quarantined per row. Partial-success imports are Phase 6
  work.

### Verification

```bash
make backend-test

# The import pipeline and its safety guarantees
docker run --rm --network sports-betting-ai_default \
  -e RAILS_ENV=test -e DATABASE_HOST=postgres -e DATABASE_PORT=5432 \
  -e POSTGRES_USER=sports_ai -e POSTGRES_PASSWORD=local_dev_only \
  -e POSTGRES_TEST_DB=sports_betting_ai_test \
  -v "$PWD/backend:/app" -v "$PWD/data:/data:ro" -w /app \
  sports-betting-ai-backend:dev \
  bash -c 'bundle exec rspec spec/services/import'
```

Status: ✅ complete — reader, adapter, resolver, transactional importer, result
contract and manual command, verified by database-backed specs covering
idempotency, rollback, conflict preservation, promotion and uniqueness races.
