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
| 5     | Asynchronous jobs                              | ✅     |
| 6     | Historical data pipeline                       | ✅     |
| 7     | Feature engineering                            | ⬜     |
| 8     | Statistical baseline and ML API                | ⬜     |
| 9     | Supervised learning and evaluation             | ⬜     |
| 10    | Prediction persistence and scheduled inference | ⬜     |
| 11    | Results synchronisation and evaluation         | ⬜     |
| 12    | Mobile application                             | ⬜     |
| 13    | Full integration and CI                        | ⬜     |
| 14    | Operational readiness                          | ⬜     |

| Milestone | Scope                                        | Status |
| --------- | -------------------------------------------- | ------ |
| E2        | Leakage-safe Elo benchmark and fair comparison | 🚧     |

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
  no match id. The stored identifier is prefixed with the canonical competition and
  season ids: a fixture recurs every season, so the bare natural key alone would
  make 2025/26 resolve to the 2024/25 match. A duplicate mapping means "already
  imported" and is reused, not re-created.

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

### Path allowlist

An import path is untrusted input. `Import::SourcePath` resolves it with
`File.realpath` and requires it to sit inside an approved root: `/data` (the
Compose mount), the repository's `data/` directory, or any directory listed in
`IMPORT_ALLOWED_ROOTS` (colon-separated, directories only). Symlinks cannot
escape the boundary because comparison happens on the resolved path.

## Phase 5 — Asynchronous jobs ✅

Runs the Phase 4 import in the background through the existing Sidekiq/Redis
infrastructure. Still one file per job: no scheduling, no recurring polling and no
bulk multi-season ingestion, which are Phase 6.

### Jobs

- `ApplicationJob` is the base class. `config/application.rb` selects the Sidekiq
  adapter outside the test environment and the ActiveJob test adapter inside it,
  so specs never touch Redis.
- `ImportFootballDataJob` (`queue_as :imports`) takes a file path and a season
  label — two strings, so nothing depends on an ActiveRecord object surviving
  serialisation through Redis. It validates the path and season, delegates entirely
  to `Import::MatchImporter`, and adds no import logic of its own.
- `spec/jobs/application_job_spec.rb` pins the execution contract so the first real
  job cannot silently break it.

### Failure semantics

| Situation | Behaviour |
| --------- | --------- |
| Rejected file, bad row, completed-result conflict | `ImportFailed`. Permanent; not retried. The job is marked failed rather than reporting success. |
| Missing file, path outside the allowlist, invalid season label | `ImportFailed`. Permanent. |
| Connection loss, deadlock, lock-wait timeout, Redis failure | `TransientFailure`, retried up to `MAX_RETRIES` (3) with a 30s wait plus Sidekiq backoff. |
| Programming error | Propagates unchanged. Never masked, never reported as success. |

Retrying is safe because the importer is idempotent: a retry that runs after a
partially completed attempt reuses everything the first attempt wrote and can
never overwrite a stored completed result.

Only the first row error is logged per run, so a badly broken file cannot flood
the log. Log lines carry the file's basename, the season label and the summary —
never file contents or credentials.

### Worker prerequisites

The `sidekiq` Compose service mounts the same `./data:/data:ro` volume as `web`.
Without that the worker cannot see the paths the web service accepts. The
`imports` queue is declared in `config/sidekiq.yml` so it is consumed
independently of `default`.

### Verification

```bash
make backend-test

# Focused job specs
docker run --rm --network sports-betting-ai_default \
  -e RAILS_ENV=test -e DATABASE_HOST=postgres -e DATABASE_PORT=5432 \
  -e POSTGRES_USER=sports_ai -e POSTGRES_PASSWORD=local_dev_only \
  -e POSTGRES_TEST_DB=sports_betting_ai_test \
  -v "$PWD/backend:/app" -v "$PWD/data:/data:ro" -w /app \
  sports-betting-ai-backend:dev \
  bash -c 'bundle exec rspec spec/jobs'

# Real worker round trip
docker compose --profile application up -d sidekiq
docker compose --profile application exec -T web \
  bundle exec rails runner 'ImportFootballDataJob.perform_later("/data/fixtures/football_data_premier_league_sample.csv", "2024/25")'
docker compose --profile application logs sidekiq
```

Enqueueing alone proves nothing; the worker log must show the job picked up from
the `imports` queue and finishing within a few hundred milliseconds.

Status: ✅ complete — the single-file import is enqueueable, executes through the
configured Sidekiq worker, has a tested retry/failure policy, and leaves the
import foundation's guarantees intact.

### Limitations and deferred work

- Only the football-data.co.uk adapter exists. A second provider needs a new adapter
  class and its own external-identifier namespace; the importer is unchanged.
- Only single-file, single-season imports are supported in this phase. Multi-season
  and multi-league bulk ingestion, scheduling and retries are Phase 6 work.
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

## Phase 6 — Historical data pipeline ✅

Ingests multiple seasons of football-data.co.uk CSV files through a validated
YAML manifest. Each file is imported through the Phase 4 single-file importer,
which is transactional on its own; one failure does not abort the remaining
entries. The runner owns no import logic — it delegates every file to
`Import::MatchImporter`.

### Layers

| Layer | Class | Responsibility |
| ----- | ----- | -------------- |
| 1. Declare | `Import::Manifest` + `history_manifest.yml` | A validated, immutable list of historical files, each with its own season and competition code. Duplicates are rejected, not deduplicated. |
| 2. Orchestrate | `Import::HistoryRunner` | Sequential multi-file import (CONCURRENCY = 1), one entry per call to `Import::MatchImporter`. Each entry carries its own season so files cannot bleed into one another. |
| 3. Run | `Import::HistoryCommand` + `rake import:historical` | Validate manifest path and season label, load the manifest, run the runner, print a concise report, exit non-zero on failure. |

### Import manifest

The manifest is a YAML list of entries:

```yaml
- path: /data/fixtures/football_data_premier_league_sample.csv
  season: 2024/25
  competition: E0
- path: /data/fixtures/football_data_premier_league_sample_mixed_statuses.csv
  season: 2025/26
  competition: E0
```

Every entry names its own season label — it is never inferred from fixture dates.
Duplicate entries (same season + competition, or same file listed twice) are
rejected rather than guessed at.

### Outcome semantics

A multi-file history import is NOT globally atomic, and pretending otherwise
would be a lie an operator could act on. If file 3 of 5 fails, files 1-2 stay
imported. The `RunOutcome` reports:

- `success?` — true only when every entry succeeded
- `failure?` — true when at least one entry failed
- `partial?` — true when some entries succeeded and some failed
- `summary` — e.g. "2 of 3 files imported, 1 failed"
- `failures` — one `EntryFailure` per failed entry, carrying the entry path and error

### Idempotency

Re-running the whole manifest is safe: each file import is idempotent, so a
second run reports every row as `skipped` and no table counts change.

### Manual import command

```bash
docker compose --profile application exec -T web \
  bundle exec rake "import:historical[/data/fixtures/history_manifest_sample.yml,2024/25]"
```

Both arguments are required and validated before the runner starts. The task
prints a summary plus at most ten entry failures, and exits non-zero on failure.

### Runbook

`backend/README.md` documents the complete `import:historical` runbook.

### Verification

```bash
make backend-test

# Focused import specs
docker run --rm --network sports-betting-ai_default \
  -e RAILS_ENV=test -e DATABASE_HOST=postgres -e DATABASE_PORT=5432 \
  -e POSTGRES_USER=sports_ai -e POSTGRES_PASSWORD=local_dev_only \
  -e POSTGRES_TEST_DB=sports_betting_ai_test \
  -v "$PWD/backend:/app" -v "$PWD/data:/data:ro" -w /app \
  sports-betting-ai-backend:dev \
  bash -c 'bundle exec rspec spec/services/import'
```

Status: ✅ complete — manifest validation, sequential multi-file orchestration,
partial-failure reporting, idempotent re-runs, and the `import:historical`
command are covered by 31 examples across `manifest_spec.rb`, `history_runner_spec.rb`
and `history_command_spec.rb`, all passing.


## Milestone E2 — Leakage-safe Elo benchmark and fair model comparison 🚧

Scope: put the 1X2 / Over-Under 2.5 / BTTS comparison on a defensible footing.
A model that is only compared with a coin flip has not been evaluated; a model
chosen on the data it is then reported on has not been evaluated honestly.
Status is 🚧, not ✅, because the test partition is no longer pristine — see
"Evaluation limitations" below.

### Evaluation methodology

| Guarantee | How it is enforced | Test |
| --------- | ------------------ | ---- |
| Chronological split | Rows sorted by `(kickoff_at, match_id)`; 60/20/20; never shuffled | `test_split_is_chronological_and_disjoint`, `test_split_uses_chronology_even_when_input_is_shuffled` |
| Boundaries do not split a round | `_boundary_at_or_after` advances past equal kickoffs | `test_split_keeps_simultaneous_kickoffs_together` |
| Common eligible samples | One `build_rows` call per market; every candidate is scored on the identical `Split` object | `test_compare_models_scores_every_candidate_on_the_same_rows` |
| Baselines fit on train only | `Baseline.majority` / `.frequency` take train rows; factories receive `split.train` | `test_factory_never_receives_validation_or_test_rows` |
| Class ordering | Explicit `MARKET_CLASSES` (`H/D/A`, `Over/Under`, `Yes/No`); `_align` reorders model output | `test_class_orders_are_canonical` |
| Probability handling | Every candidate must return one row per input row, columns in class order, summing to 1 | `test_elo_probabilities_come_out_in_the_harness_class_order` |
| No current-match or future leakage | Features see strictly earlier kickoffs; Elo predicts a whole round before applying any result | `test_a_future_match_cannot_change_an_earlier_rows_features`, `test_a_rows_own_result_does_not_change_its_own_prediction` |
| Reproducibility | Fixed bootstrap seed; deterministic model `random_state`s; `(kickoff_at, id)` total order | `test_paired_bootstrap_is_reproducible_for_a_fixed_seed` |

Selection uses **validation log loss only**. The harness records
`validation_ranking`, `selected_by_validation_log_loss` and
`validation_log_loss_of_selected` in every report, and never lets a test number
influence the choice.

### Leakage-safe Elo benchmark (`ml/app/elo.py`)

Parameters are fixed constants, documented in the module, and **not tuned on
this dataset** — so the model cannot have been fitted to validation:

| Parameter | Value | Basis |
| --------- | ----- | ----- |
| `INITIAL_RATING` | 1500 | Conventional neutral start |
| `K` | 20 | World Football Elo Ratings standard |
| `DEFAULT_HOME_ADVANTAGE` | 60 rating points | ≈ the 60-65 point home edge reported for European leagues; applied when forming the expected score, never stored in ratings |
| `DEFAULT_DRAW_RATE` | 0.25 | League-typical draw frequency; anchors the draw model |
| Margin of victory | none (1.0) | No fitted parameter; the market does not grade margins |

Probability construction: the expected score `w` gives a draw probability
`0.25 × 4w(1−w)` (peaks at an even match, vanishes at a mismatch); the remaining
mass is split `w : (1−w)` between H and A, then normalised.

Timing is structural rather than merely tested: `predict_chronologically` reads
the rating table, emits probabilities, and only then applies the results for
that round. Same-kickoff matches are grouped, so simultaneous fixtures cannot
affect each other and a team cannot see a result from its own round. Missing or
blank kickoffs sort deterministically first; ties always break on match id.

Over/Under and BTTS are **not** Elo outputs. The harness uses the train
frequency as a documented placeholder and the report says so in `notes`.

### Comparison results

Same 4,260 completed matches, same 60/20/20 chronological split
(train 2,559 · 2022-03-13 → 2022-03-13; validation 849 → 2024-05-14; test 852 →
2026-10-25). Test class distribution 1X2: H 354 / D 220 / A 278.

**1X2** (test figures are exploratory):

| Model | val log loss | test log loss | test acc | test Brier | ΔLL vs frequency | 95% paired CI |
| ----- | -----------: | ------------: | -------: | ---------: | ---------------: | ------------- |
| majority | 18.2254 | 20.1882 | 0.4155 | 1.1690 | +19.1064 | [+17.991, +20.223] |
| frequency | 1.0532 | 1.0818 | 0.4155 | 0.6554 | baseline | — |
| logistic_regression | **1.0002** | 1.0390 | 0.4812 | 0.6244 | −0.0428 | [−0.068, −0.018] |
| hist_gradient_boosting | 1.4073 | 1.4156 | 0.4448 | 0.7621 | +0.3338 | [+0.250, +0.420] |
| poisson_goals (proxy) | 1.0761 | 1.1023 | 0.4249 | 0.6647 | +0.0205 | [−0.015, +0.053] |
| **elo** | **0.9883** | 1.0886 | 0.4343 | 0.6598 | +0.0068 | [−0.021, +0.034] |

**Over/Under 2.5**: frequency 0.6865 val / 0.6890 test; logistic 0.6844 / 0.6870
(ΔLL −0.0020, CI [−0.008, +0.004]); Elo = frequency placeholder (ΔLL 0.0000);
GBM +0.0915 and Poisson proxy +0.0746 both significantly worse.

**BTTS**: frequency 0.6923 / 0.6923; logistic 0.6979 / 0.6978 (ΔLL +0.0055,
CI [−0.002, +0.014], indistinguishable); Elo = frequency placeholder;
GBM +0.1437 and Poisson proxy +0.0665 both significantly worse.

Reading of the 1X2 result: Elo has the best *validation* log loss but does not
beat the frequency baseline on test (+0.0068, CI spans zero), while logistic
regression beats the baseline by 0.043 with a CI excluding zero. The two are
statistically indistinguishable on this test partition — Elo's validation edge
is within noise of the selection metric.

### Metric definitions

- **Log loss** — mean negative log probability of the true class.
- **Multiclass Brier** — `(1/N) Σᵢ Σₖ (pᵢₖ − yᵢₖ)²`, the unscaled sum variant.
  Range [0, 2] for K classes. **Only comparable within the same class list** —
  never compare a 3-class Brier with a 2-class one. With K = 2 it is twice the
  textbook binary Brier, which is why binary markets look "worse" than 0-1 suggests.
- **ΔLL vs baseline** — model log loss minus frequency-baseline log loss on the
  same rows; negative is better.
- **95% CI** — paired bootstrap, 2,000 resamples, seed 20240529, both models
  scored on the same resampled rows. An interval containing 0 cannot separate
  the models.

### Evaluation limitations

1. **The test partition is exploratory, not an untouched holdout.** It was
   already scored by an earlier version of this harness before Elo, the
   candidate set and the metric reporting were revised. Every `evaluation_*.json`
   carries `"test_partition_status": "exploratory"` and an explanation. The
   selection metric (validation) was not consulted during those revisions, so the
   *ranking* remains defensible, but the test *numbers* are biased optimistic.
2. **A defensible final estimate needs fresh data.** Import seasons after
   2026-10-25 and score once. Do not re-tune on the current test period and call
   it final.
3. **No hyperparameter search.** Logistic `C=1.0` and the GBM defaults were not
   tuned; a tuned model would need nested selection inside train.
4. **Poisson is a proxy**, not a fitted regression — its strengths come from the
   row's own last-5 features. It is internally consistent across markets but not
   a calibrated goal model.
5. **Elo ignores venue-neutral asymmetry and squad changes**; K and home
   advantage are league-agnostic constants.
6. **No match-confidence calibration curve is fitted**; reliability tables are
   reported but no isotonic/Platt layer is applied.
7. **Single dataset.** One competition family (English league data) and one
   provider; results do not generalise to other leagues without re-running.

### Verification

```bash
# Targeted: Elo mechanics, evaluation methodology, harness integration
docker compose run --rm --entrypoint python ml -m pytest \
  ml/tests/test_elo.py ml/tests/test_evaluation.py ml/tests/test_harness.py -q
# 62 passed

# Whole ML suite
docker compose run --rm --entrypoint python ml -m pytest ml/tests -q
# 178 passed

# Benchmark (writes ml/artifacts/evaluation/*.json; never a production artifact)
docker compose run --rm --entrypoint python ml -m ml.app.evaluate_markets
docker compose run --rm --entrypoint python ml -m ml.app.evaluate_markets --market 1x2

# Backend regression
make backend-test
# 723 examples, 0 failures
```

Note: `docker compose run` uses the prebuilt image. After editing `ml/`, run
`docker compose build ml` first — `ml/artifacts` is bind-mounted, the source is not.

Status: 🚧 in progress — Elo benchmark, harness integration, paired uncertainty
and the exploratory marker are complete and tested. Remaining work is a fresh
final holdout (limitation 1 and 2). **No production artifact was promoted**; the
current validation ranking does not justify replacing the deployed 1X2 model,
and nothing here demonstrates profitability or betting readiness.

### Validation-side uncertainty (1X2)

Because selection happens on validation, the CI that matters for choosing a
model is the validation one. Paired bootstrap over the 849 validation rows
(2,000 resamples):

| Model | val ΔLL vs frequency | 95% paired CI | P(better) |
| ----- | -------------------: | ------------- | --------: |
| logistic_regression | −0.0530 | [−0.0796, −0.0273] | 1.000 |
| elo | −0.0650 | [−0.0903, −0.0397] | 1.000 |
| poisson_goals (proxy) | +0.0229 | [−0.0150, +0.0604] | 0.123 |
| hist_gradient_boosting | +0.3540 | [+0.2668, +0.4365] | 0.000 |

Both Elo and logistic regression beat the frequency baseline on validation with
intervals excluding zero. Neither is shown to beat the **other** — Elo's 0.012
validation edge over logistic regression is the entire basis for its top
ranking, and it reverses on test. There is no defensible case for promoting
either over the deployed model on this evidence.

## Completion Program — Progress Ledger

Maintained across sessions. Each entry records inspected state, commands run,
outcomes, blockers and the next action. **Technical completion**, **statistical
validation** and **production readiness** are tracked separately and are never
conflated.

### Phase 0 — Recovery and baseline (2026-10-29)

**Repository state.** Branch `main`, 60 dirty entries (47 untracked, 13
modified), no commits since `4afedc3`. All prior work preserved; nothing reset.

| Area | State found |
| ---- | ----------- |
| ML evaluation | `elo.py`, `evaluation.py`, `evaluate_markets.py` complete; harness, Elo and paired-bootstrap suites present |
| Data import | `football-data.co.uk` adapter, downloader, manifest/history runner, `ImportFootballDataJob` complete |
| Predictions | `Predictions::{Predictor,MarketPredictor,FeatureBuilder,MatchHistory}` complete; double chance derived from stored 1X2 only |
| Scheduling | **Absent** — no Sidekiq-Cron, no recurring job definitions, no scheduler container |
| Fixture/result sync | **Absent** — only historical CSV import; no scheduled-fixture fetch or completed-result reconciliation |
| Sync observability | **Absent** — no run records, no last-success status |
| Release workflow | **Absent** — no candidate/production separation, no promote/rollback |
| Mobile | **Absent** — `mobile/` is an empty directory |

**Data coverage** (`sports_betting_ai_development`): 4,260 completed matches,
2015-08-08 → 2026-10-25; 1 scheduled match on 2026-12-26. 12 seasons, 380
matches each except 2025/26 (381), 2026/27 (80 partial). Provider is
football-data.co.uk (free, CSV, no live fixture feed). **No completed matches
exist after 2026-10-25**, so no genuinely new holdout is available.

**Baseline test results (pre-existing, all green):**

```bash
make backend-test                                      # 723 examples, 0 failures
docker compose run --rm --entrypoint python ml -m pytest ml/tests -q
                                                       # 178 passed
```

**Service health:** web, ml, postgres, redis healthy; sidekiq up (no healthcheck).

**Blockers identified.**

| ID | Blocker | Class |
| -- | ------- | ----- |
| B1 | No completed matches after 2026-10-25 → no untouched final holdout | Data availability / statistical validation |
| B2 | football-data.co.uk publishes season CSVs, not a fixture/result feed; there is no free provider configured for upcoming fixtures | External dependency |
| B3 | `mobile/` contains no application | Code |

**Next incomplete task:** Phase 1 — reproduce E3 results and freeze the
evaluation configuration, then Phase 2 onward.

### Phase 1 — Valid model evaluation (E3) — COMPLETE (technical)

**Reproduction before relying on prior reports.** Re-ran the full benchmark in a
fresh container into a bind-mounted scratch directory and diffed the JSON against
the stored reports (`generated_at`/`environment` excluded):

```
1x2 IDENTICAL   over_under_2.5 IDENTICAL   btts IDENTICAL
```

The earlier numbers are reproducible, not stale.

**Data availability.** 4,260 completed matches, 2015-08-08 → 2026-10-25. The
provider's current-season CSV (`data/raw/2627_E0.csv`) contains completed rows
through 2026-10-25 and no later. **No completed match exists after 2026-10-25**,
so blocker B1 stands: there is no genuinely new holdout yet.

**Protocol freeze (new).** `ml/app/evaluate_markets.py` now freezes everything
that makes two evaluations comparable: split fractions and ordering rule,
selection rule, delta baseline, bootstrap settings, Elo constants, feature
schema, candidate list per market and class orders.

- `current_protocol()`, `protocol_digest()`, `load_frozen_config()`, `write_freeze()`
- `python -m ml.app.evaluate_markets --freeze` writes the record
- `ml/artifacts/evaluation/protocol_freeze.json`, digest
  `2779ec88a8175fcdc6a92aa6745b0c56e47fb8e7f1eb58a47f72275ad8695a96`
- The record explicitly states `holdout_status: exploratory` and why the current
  test partition is contaminated, so it cannot be mistaken for a pristine holdout.
- Every evaluation report now carries `protocol_digest`, so a future holdout
  scored under a drifted protocol is detectable.

**Tests.** 4 new freeze tests (`test_harness.py`); full ML suite **182 passed**.

**Selection remains validation-only.** 1X2: `elo` (0.9883) narrowly leads
`logistic_regression` (1.0002) on validation, but the validation-side paired CI
gives Elo −0.0650 [−0.0903, −0.0397] and logistic −0.0530 [−0.0796, −0.0273] vs
the frequency baseline — both beat the baseline, **neither is shown to beat the
other**. No promotion is justified by this evidence.

**Next modelling experiment (justified by evidence, not speculation):**
prequential (rolling-origin) evaluation. Both top models are plausibly
distinguishable only with more folds than one 60/20/20 split provides; the Elo
validation edge (0.012) reverses on test, which is the signature of a difference
smaller than the sampling noise of a single split. Do this *before* trying new
features or hyperparameters.

**Next incomplete task:** Phase 2 — data pipeline reliability.

### Phase 2 — Data pipeline reliability — COMPLETE

**Defect found and fixed: rescheduled fixtures were silently mishandled.**

The provider publishes no match id, so its key embeds the kickoff. A moved
fixture therefore arrives under a *new* key. Before this fix:

- the exact-key lookup missed,
- `mapped(:match, ...)` built a **second** match for the same fixture,
- so a reschedule duplicated the match — corrupting both training and evaluation,
- and a same-key row with a changed kickoff was reported `:skipped`, leaving a
  stored kickoff that no longer existed.

**Fix** (`Import::ReferenceResolver`, `Import::MatchImporter`):

- `find_rescheduled_match` runs **only** when the exact key misses.
- It matches on same competition + season + both teams **in the same home/away
  orientation**, and only a fixture that **has no result**.
- It merges only when exactly **one** such unresolved fixture exists; with two
  candidates it refuses to guess and creates nothing, rather than risk merging
  the wrong match.
- The new provider key is recorded against the existing match (so the fixture is
  idempotent on its new key) while the old key is retained for audit.
- `reconcile` now applies a kickoff change to a non-completed fixture and reports
  `:updated` instead of `:skipped`.
- A stored result is never disturbed by a fixture-only row, and a contradicting
  result still aborts (pre-existing behaviour, now covered by a regression test).

**Tests** (`backend/spec/services/import/reschedule_reconciliation_spec.rb`,
7 examples, written first and observed failing):

| Behaviour | Test |
| --------- | ---- |
| Reschedule moves the fixture and reports `updated` | `moves a scheduled fixture...` |
| No duplicate match is created | same + `is idempotent...` |
| Re-import of the moved fixture is a skip | `is idempotent...` |
| Old provider identifier retained, new one added | `keeps the original provider identifier...` |
| Stored result untouched by a fixture-only row | `does not disturb a stored result...` |
| Conflicting result rejected | `rejects a conflicting result...` |
| Different clubs / reversed fixture are not merged | `does not match an unrelated club`, `does not match the reverse fixture` |

**Already satisfied before this phase (verified, not assumed):** idempotent
re-imports, transactional batches with full rollback, completed→scheduled
downgrade rejection, raw downloads are atomic + checksummed + provenance-
recorded (`*.metadata.json`), source host allowlist, bounded retries on
transient errors only, and `Import::Result` reporting
`created/updated/skipped/rejected` plus per-row errors.

**Tests.** Focused 7/7; full backend suite **730 examples, 0 failures**.

**Provenance / licensing.** Data source is football-data.co.uk (free, public
season CSVs). Documented in `data/manifests/*.yml` headers and in Phase 9's
operator section.

**Next incomplete task:** Phase 3 — training and prediction contracts.

### Phase 3 — Training and prediction contracts — COMPLETE

**Defects found and fixed.**

1. **Double chance was broken in production.** `predict`/`predict_market` loaded
   a `double_chance` artifact that does not exist, so the market returned 503.
   It only appeared to work because a test injected an artifact for every
   market. Fixed with `_artifact_market()` / `DERIVED_MARKET_SOURCE`, which map
   the derived market onto the **1X2** artifact; the model cache is now keyed on
   the artifact market so the bundle is not loaded twice. Verified live:

   ```
   1x2            -> H 0.3423, D 0.1064, A 0.5514          (v0.3.0)
   double_chance  -> 1X 0.4486, X2 0.6577, 12 0.8936       (v0.3.0)
   1X + X2 + 12   = 2.0000  (overlapping events, by construction)
   over_under_2.5 -> Over 0.7107, Under 0.2893             (v0.4.0)
   btts           -> No 0.6321, Yes 0.3679                 (v0.4.0)
   ```

2. **Binary artifacts were mislabelled `1x2`.** `ModelBundle.market` defaulted
   to `"1x2"` and `train_binary_classifier` never set it, so the Over/Under and
   BTTS artifacts on disk both claim `market: "1x2"` — the field an operator
   reads when choosing a file to roll back. Fixed at the source:
   - `ModelBundle.market` now defaults to `UNKNOWN_MARKET`, never `1x2`.
   - `train_binary_classifier(..., market=...)` and `train_over_under` /
     `train_btts` pass the correct market; `train_baseline` sets `1x2`.
   - `TRAINED_MARKETS` / `DERIVED_MARKETS` are exported so double chance cannot
     acquire an artifact.
   - Inference now **refuses** a contradicting market (a three-class 1X2 artifact
     served as BTTS, or a BTTS artifact served as Over/Under).
   - A **legacy** binary artifact stamped `1x2` is still served (a two-class
     model without H/D/A provably cannot be 1X2), with a warning logged, so a
     working deployment is not broken by a metadata-only defect. The artifacts on
     disk are therefore unchanged and still report `1x2`; they are corrected on
     the next retrain. Documented as a known inconsistency.

**Tests** (`ml/tests/test_contracts.py`, 21 examples, written first and observed
failing): market round-trip per market, `UNKNOWN_MARKET` default, trained/derived
market partition, double-chance invariants for degenerate 1X2 (1/0/0, 0/1/0,
0/0/1, near-uniform) including `Σ = 2` and complement identities, double chance
served from the 1X2 artifact and equal to its projection exactly, refusal of a
three-class artifact as a binary market, refusal of the wrong binary market,
tolerance of the legacy label.

**Full ML suite:** **203 passed**.

**Not changed:** production artifact files (no retrain, no overwrite).

**Next incomplete task:** Phase 4 — model selection and release safety.

### Phase 4 — Model selection and release safety — COMPLETE

**Gap found.** Before this phase `training.py` wrote straight to
`/app/artifacts/model.joblib` — the file inference serves. Any retrain was an
uncontrolled production deployment, and because daily synchronization changes
the training set, an import would have become a deployer. There was no candidate
store, no promotion gate and no rollback.

**Implemented** (`ml/app/release.py`, `ml/app/release_cli.py`).

| Step | Mechanism |
| ---- | --------- |
| Train | `ReleaseStore.save_candidate()` → `candidates/<market>/<sha256>.joblib`, content-addressed, plus a sidecar `.json` with market, hash, version, classes, `trained_at` |
| Evaluate | `ml.app.evaluate_markets` — unchanged, and a test asserts it cannot import `release`: evaluation must not gain the power to promote |
| Promote | `ReleaseStore.promote()` — gated, archiving the outgoing artifact first, then a single atomic `os.replace` |
| Rollback | `ReleaseStore.rollback()` — consumes the newest archive, restores byte for byte |
| Audit | `release_journal.jsonl` — one JSON line per transition with time, action, market, hashes and reason |

**Promotion gate — each condition has its own test, all refused by default:**

- no evaluation report present,
- report scores a **different candidate** (promoting A on B's score),
- report produced under a **different protocol digest**,
- report does not say the candidate **beats the baseline**,
- market is **derived** (double chance must never have an artifact),
- artifact fails to load (validated *before* the swap).

`build_report_from_evaluation()` derives `beats_baseline` from the **paired
bootstrap CI**, not the point estimate: the validation log-loss delta CI must lie
entirely below zero. A mere point-estimate improvement is exactly how a
difference smaller than sampling noise gets promoted.

**CLI** (`python -m ml.app.release_cli ...`): `status`, `candidates`,
`promote`, `rollback`, `report`, `protocol-digest`. No `--force` flag exists.
Exit codes 0 / 1 (gate refused) / 2 (missing file).

**Live verification against the real artifact directory:**

```
$ python -m ml.app.release_cli status
production: 1x2 <sha>, over_under_2.5 <sha>, btts <sha>; archived: all 0; recent: []
$ python -m ml.app.release_cli protocol-digest
2779ec88a8175fcdc6a92aa6745b0c56e47fb8e7f1eb58a47f72275ad8695a96
```

**Tests** (`ml/tests/test_release.py`, 21 examples, written first): candidate
isolation, content addressing, atomic-swap failure leaving production intact,
every gate refusal, promote→archive→rollback round trip, journal contents, and
the structural "no promotion path from synchronization" check.

**Production artifacts were not modified.** Their timestamps are unchanged; no
candidate has been promoted, because Phase 1 showed no candidate is separable
from its rival, let alone clearly better than the deployed model.

**`ml/artifacts/candidates/`, `archive/`, `release_journal.jsonl` and
`*.joblib` are now gitignored** — previously the artifact directory was
untracked-but-visible, which would have committed binary models.

**Next incomplete task:** Phase 5 — Rails API and backend integration.

### Phase 5 — Rails API and backend integration — COMPLETE

**Verified live over the Compose network** (not from specs alone):

| Check | Result |
| ----- | ------ |
| `/api/v1/health`, `/api/v1/ready` | 200 |
| `/api/v1/model_status?market=…` | 200 for all four markets |
| `GET /api/v1/predictions` | 200, all four markets present |
| `GET /api/v1/predictions/:match_id` | 200, four current predictions with per-market `model_version` |
| `POST` with unknown match | 404 |
| `POST` without `match_id` | 400 |
| `POST` without `markets` | 400 (by design: no accidental fan-out to four model calls) |
| Completed match | 422 |
| ML container stopped | **503**, per-market `errors`, clean message, **no stack trace** |
| ML container restarted | recovers without a Rails restart |
| `GET /api/v1/predictions/4280` | double chance `1x` 0.91247 = 1X2 `H` 0.63552 + `D` 0.27695 ✓ |

**Defect found and fixed: double chance depended on request ordering.**

`MarketPredictor#call` delegated `double_chance` to `derive_double_chance`,
which required a *stored* 1X2 prediction and otherwise failed. A client asking
for only double chance — a mobile screen, a scheduled job — got "unsupported"
for a reason unrelated to the market. The controller only fan-out-ordered
because callers happened to request all four markets.

Fixed by `ensure_1x2`: when no current 1X2 exists, the predictor fetches and
stores it, then derives. Guarantees preserved:

- double chance is still **never trained** — the only model called is `1x2`,
- the projection is still `P(H)+P(D)`, `P(D)+P(A)`, `P(H)+P(A)`,
- the stored 1X2 is reused on later calls (no duplicate model calls),
- an ML outage surfaces as **transient**, so the failure is retryable rather than
  a permanent "unsupported market".

**Contract change, deliberate and documented.** A pre-existing spec asserted the
old failure ("fails when there is no 1x2 prediction to derive from"). It was
rewritten — not deleted — to assert the new behaviour (derives from a freshly
fetched 1X2) *and* to keep an equivalent failure case (ML cannot supply 1X2 →
failure with a 1X2/unreachable message). This is the only pre-existing spec whose
expectation changed.

**Tests.** New `spec/services/predictions/double_chance_bootstrap_spec.rb`
(6 examples): standalone derivation, exact projection values, one stored 1X2
across repeated calls, no redundant ML call when 1X2 is stored, transient error
propagation, completed-match refusal. Full backend suite: **737 examples,
0 failures**.

**Authentication:** no endpoint is authenticated by design — this is a read-only
public prediction API with no user data and no write surface beyond prediction
creation. Recorded in Phase 9 as an explicit, current scope decision rather than
an oversight.

**Development database note.** The live API smoke tests created predictions for
the one scheduled fixture (match 4280). These are ordinary predictions in the
dev database — the same ones a user request produces, subject to the normal
"current vs superseded" lifecycle. No match, result or historical record was
altered.

**Next incomplete task:** Phase 6 — daily automated synchronization.

---

## SESSION PAUSE — handover 2026-10-29

**Last completed phase:** Phase 5 — Rails API and backend integration
(737 examples, 0 failures). Phases 0–5 complete and recorded above.

**In progress:** Phase 6 — daily automated synchronization. Done so far:

- `backend/db/migrate/20261029120000_create_sync_runs.rb` (migration **applied**
  to the test DB; **not yet applied to development**)
- `backend/app/models/sync/sync_run.rb` — ledger, partial unique index for
  overlap protection, stale reclamation, secret redaction, `status_summary`
- `backend/app/services/sync/{season_window,base_synchronizer,fixture_synchronizer,result_synchronizer}.rb`
- `backend/spec/services/sync/sync_run_spec.rb` — **15/15 passing**
- `backend/spec/services/sync/synchronizers_spec.rb` — **written, NOT YET RUN**
- `backend/Gemfile` — added `gem "sidekiq-cron", "~> 2.1"`

**Known blocker:** `Gemfile.lock` was **not updated** for `sidekiq-cron`. The
`docker compose build web` run completed ("Image sports-betting-ai-web Built"),
so the image resolves the gem at build time, but the lockfile has no entry —
`bundle install` in the image regenerated inside the layer, not on the host.
This must be resolved before the scheduler can be trusted as reproducible.

**Environment note:** the prior `Timeout` output was my `sleep` wrapper being
killed, not the build. No migration, import or file write was interrupted.

**Nothing was reset, stashed, cleaned, committed or pushed. No container or
volume was removed.** ML artifacts untouched; no candidate promoted.

**Next action tomorrow:** run
`docker compose run --rm --entrypoint python ml -m pytest ml/tests -q` and
`make backend-test`, then execute, in order:

1. `docker run --rm --entrypoint bundle -v "$PWD/backend:/app" -w /app sports-betting-ai-backend:dev lock --update sidekiq-cron`
   and confirm `sidekiq-cron` + `fugit` appear in `Gemfile.lock`.
2. `bin/rails db:migrate` (development DB).
3. `bundle exec rspec spec/services/sync/` — fix `synchronizers_spec.rb`.
