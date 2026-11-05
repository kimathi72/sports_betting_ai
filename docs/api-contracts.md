# Rails API contracts — source of truth for the mobile client

Status: **verified against the running backend on 2026-10-30** (Docker Compose
`web` service, real PostgreSQL, real ML container). Every field below was
observed in a live response or asserted by a request spec — nothing here is
inferred from source alone.

- Owner (backend): this agent.
- Consumer: Kilo Code's Expo / React Native TypeScript app in `mobile/`.
- Base URL in development: `http://localhost:3000`
- From an Android emulator: `http://10.0.2.2:3000`
- From a physical device on the same network: `http://<host-LAN-IP>:3000`
  (`localhost` on a phone means *the phone*.)

> **The mobile app talks to Rails only.** It must never call the FastAPI service
> directly. Rails owns prediction orchestration, persistence and market rules.

## Conventions that apply to every endpoint

| Item | Contract |
| --- | --- |
| Content type | `application/json; charset=utf-8` |
| Authentication | **None.** No endpoint requires a token, cookie or API key. There are no user accounts. |
| Required headers | Only `Content-Type: application/json` on `POST`. |
| Timestamps | UTC ISO 8601 with a `Z`, e.g. `2026-10-30T08:38:24Z`. Always UTC regardless of server TZ. |
| Errors | A JSON object with a top-level `error` string: `{"error": "..."}`. Some prediction endpoints also include `errors` (per-market) and `match_id`. |
| Pagination | There is **no** page/offset pagination anywhere. Collections are capped with `limit` (see each endpoint). |
| CORS | Enabled for configurable browser origins — see [CORS](#cors). |
| Trailing slash | Not used. Paths are exact (`/api/v1/matches`, not `/api/v1/matches/`). |

### Error response format

Every error response is JSON, never HTML, and never contains a stack trace, SQL
or an internal exception message:

```json
{ "error": "status must be one of: scheduled, postponed, cancelled, in_progress, completed" }
```

The prediction `POST` additionally uses an `errors` object keyed by market (see
that endpoint). Always read `error` when present; treat any non-2xx as a failure.

### Route summary (from `rails routes`)

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/up` | Rails liveness (load balancer / Compose healthcheck only) |
| GET | `/api/v1/health` | API liveness |
| GET | `/api/v1/ready` | Readiness (database) |
| GET | `/api/v1/competitions` | Competitions |
| GET | `/api/v1/teams` | Teams |
| GET | `/api/v1/seasons` | Seasons (+ match counts) |
| GET | `/api/v1/matches` | Matches (fixtures and results) |
| GET | `/api/v1/predictions` | Stored predictions (collection) |
| POST | `/api/v1/predictions` | Request predictions |
| GET | `/api/v1/predictions/:id` | Current predictions for a match |
| GET | `/api/v1/model_status` | Which model versions produced predictions |
| GET | `/api/v1/sync/status` | Daily synchronization health |

> ⚠️ **`GET /api/v1/predictions/:id` — `:id` is the MATCH id, not a prediction
> id.** The route is `resources :predictions, only: [:show]`, so Rails names the
> parameter `:id`, but the controller looks up `Prediction.where(match_id: …)`.
> Inside `Api::V1::PredictionsController#show` it is read as `params[:id]` and
> interpreted as a match. There is **no** `GET /api/v1/predictions/:match_id`
> route distinct from this one, and no way to fetch a single prediction by its
> own `id`.

---

## 1. Liveness — `GET /api/v1/health`

Process health only. Does not touch the database or any external service.

**Request:** no parameters, no body.

**Response `200`:**

```json
{ "status": "ok" }
```

**Errors:** none in normal operation. Never returns 5xx because PostgreSQL is
down — that is `/ready`'s job.

---

## 2. Readiness — `GET /api/v1/ready`

Whether the app can serve database-backed requests.

**Request:** no parameters, no body.

**Response `200`:**

```json
{ "status": "ready", "checks": { "database": "ok" } }
```

**Response `503`** (database unreachable):

```json
{ "status": "not_ready", "checks": { "database": "unavailable" } }
```

The payload never includes credentials, SQL, connection strings or exception
messages.

**Client guidance:** poll `/health` for "is the backend reachable"; use `/ready`
only to explain a failure before showing data-dependent screens.

---

## 3. Competitions — `GET /api/v1/competitions`

**Request:** no parameters (none are supported).

**Response `200`** — a bare JSON array, ordered by `name` then `id`:

```json
[
  { "id": 4, "name": "football_data competition E0", "code": "E0", "country": null }
]
```

| Field | Type | Notes |
| --- | --- | --- |
| `id` | integer | Stable within this database. |
| `name` | string | Unique display name. |
| `code` | string \| null | Provider competition code; `null` when absent. |
| `country` | string \| null | `null` when absent. |

**Not paginated. Not filtered.** Empty database → `[]` (never 404).

---

## 4. Teams — `GET /api/v1/teams`

**Request:** no parameters.

**Response `200`** — bare array, ordered by `name` then `id`:

```json
[
  { "id": 12, "name": "Arsenal", "country": null }
]
```

`normalized_name` is deliberately **not** exposed — it is an internal
deduplication key.

**Not paginated. Not filtered.**

---

## 5. Seasons — `GET /api/v1/seasons`

**Query parameters** (all optional):

| Parameter | Type | Behaviour |
| --- | --- | --- |
| `competition_id` | integer | Restrict to one competition. |
| `with_matches` | boolean (`true`/`false`) | When `true`, omit seasons with zero matches. |

**Response `200`** — bare array, ordered by `competition_id`, then season `name`
**descending** (`2026/27` before `2025/26`):

```json
[
  {
    "id": 5,
    "name": "2026/27",
    "competition_id": 4,
    "match_count": 380,
    "completed_match_count": 80
  }
]
```

Use `completed_match_count` to tell a finished season from one still in progress
without guessing from the calendar.

---

## 6. Matches — `GET /api/v1/matches`

The richest read payload: a match is a fixture and, once played, its result.

**Query parameters** (all optional, all combinable):

| Parameter | Type | Behaviour |
| --- | --- | --- |
| `competition_id` | integer | Restrict to one competition. Non-integer → `400`. |
| `season_id` | integer | Restrict to one season. Non-integer → `400`. |
| `status` | enum string | One of `scheduled`, `postponed`, `cancelled`, `in_progress`, `completed`. Anything else → **`400`**, not an empty list. |
| `limit` | integer | `1..2000` (default 2000). Above 2000 is clamped to 2000. Below 1 or non-integer → `400`. |

**Response `200`** — bare array, ordered by `kickoff_at` ascending, then `id`:

```json
[
  {
    "id": 4280,
    "competition_id": 4,
    "season_id": 5,
    "home_team_id": 12,
    "away_team_id": 37,
    "kickoff_at": "2026-12-26T15:00:00Z",
    "status": "scheduled",
    "home_score": null,
    "away_score": null
  }
]
```

- The payload carries **ids only** — resolve names client-side from
  `/competitions`, `/teams`, `/seasons`.
- `home_score` / `away_score` are `null` until the match completes; they are
  always both present or both `null`.
- `kickoff_at` is never `null`.

**Errors:** `400` for an invalid `status`, an invalid `limit`, or a
non-integer id filter:

```json
{ "error": "status must be one of: scheduled, postponed, cancelled, in_progress, completed" }
```

**Pagination:** none. Query per season (`?season_id=`) for large result sets
rather than paging the whole archive.

---

## 7. Predictions

The prediction surface is four **independent markets** about the same match:

| `market` | Canonical outcome keys | Meaning |
| --- | --- | --- |
| `1x2` | `H`, `D`, `A` | Home / Draw / Away |
| `over_under_2.5` | `over`, `under` | Total goals over/under 2.5 |
| `btts` | `yes`, `no` | Both teams to score |
| `double_chance` | `1x`, `x2`, `12` | Derived from 1X2: `1x = P(H)+P(D)`, `x2 = P(D)+P(A)`, `12 = P(H)+P(A)` |

`probabilities` are **probabilities**, not odds, and are keyed by the canonical
outcome strings above (lowercase for all but `1x2`). They sum to 1 (within
0.00002 rounding).

### 7.1 Request predictions — `POST /api/v1/predictions`

Runs the model and persists the result. **`match_id` belongs in the request
body — it is NOT part of the URL.** (This is the single most important contract
detail: `POST /api/v1/predictions/4280` does not exist and will 404.)

**Request body** (`application/json`):

```json
{ "match_id": 4280, "markets": ["1x2", "over_under_2.5", "btts", "double_chance"] }
```

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `match_id` | integer | **Yes** | The match to predict. |
| `markets` | string[] | **Yes** | One or more of the four market names. `market` (singular) is also accepted as an alias. |

`markets` is mandatory on purpose: an accidental request must not fan out to
four model calls.

**Response `201`** — every requested market succeeded:

```json
{
  "match_id": 4280,
  "predictions": [
    { "market": "1x2", "selection": "H",
      "probabilities": { "H": 0.63552, "D": 0.27695, "A": 0.08753 },
      "model_version": "0.3.0", "generated_at": "2026-10-30T08:38:24Z" },
    { "market": "over_under_2.5", "selection": "over",
      "probabilities": { "over": 0.87075, "under": 0.12925 },
      "model_version": "0.4.0", "generated_at": "2026-10-30T08:38:24Z" },
    { "market": "btts", "selection": "yes",
      "probabilities": { "no": 0.37127, "yes": 0.62873 },
      "model_version": "0.4.0", "generated_at": "2026-10-30T08:38:24Z" },
    { "market": "double_chance", "selection": "1x",
      "probabilities": { "1x": 0.91247, "x2": 0.36448, "12": 0.72305 },
      "model_version": "0.3.0", "generated_at": "2026-10-30T08:38:24Z" }
  ],
  "errors": {}
}
```

| Field | Type | Notes |
| --- | --- | --- |
| `predictions[].market` | string | One of the four market names. |
| `predictions[].selection` | string | The most likely outcome: one of that market's canonical keys. |
| `predictions[].probabilities` | object | Keyed by canonical outcomes; numbers in `[0,1]`. |
| `predictions[].model_version` | string | Version that produced this market. **Differs per market** — 1X2 and double chance come from the 1X2 model, BTTS and O/U from their own. |
| `predictions[].generated_at` | string | UTC ISO 8601. |
| `errors` | object | Empty `{}` on full success. |

**Response `207 Multi-Status`** — partial success. At least one market succeeded
and at least one failed. Same body shape; failed markets appear in `errors` and
are absent from `predictions`:

```json
{
  "match_id": 4280,
  "predictions": [ { "market": "1x2", "selection": "H", "probabilities": { "H": 0.5, "D": 0.3, "A": 0.2 }, "model_version": "0.3.0", "generated_at": "2026-10-30T08:38:24Z" } ],
  "errors": { "btts": "ML service unreachable: connection refused" }
}
```

**Status codes:**

| Code | When | Body |
| --- | --- | --- |
| `201 Created` | Every requested market succeeded. | `{match_id, predictions, errors:{}}` |
| `207 Multi-Status` | Some markets succeeded, some failed. | `{match_id, predictions, errors:{market: message}}` |
| `400 Bad Request` | `match_id` missing; `markets` missing; unknown market name. | `{"error": "..."}` |
| `404 Not Found` | No match with that `match_id`. | `{"error": "match 999999 not found"}` |
| `422 Unprocessable Entity` | Match already `completed`; or every market failed for a non-outage reason. | `{"error": "..."}` |
| `503 Service Unavailable` | Every market failed because the ML service was unreachable/timed out. Nothing is stored. | `{match_id, error, errors:{market: message}}` |

Live examples:

```text
POST {"markets":["1x2"]}                -> 400 {"error":"match_id is required"}
POST {"match_id":999999,...}            -> 404 {"error":"match 999999 not found"}
POST {"match_id":4280}                  -> 400 {"error":"markets is required, one or more of: 1x2, over_under_2.5, btts, double_chance"}
POST {"match_id":18,...} (completed)    -> 422 {"error":"a completed match already has a result and cannot be predicted"}
```

**Partial success is normal and must be rendered as such** — do not discard the
successful markets when `errors` is non-empty.

**Side effects:** `201`/`207` persist predictions (one row per market) and
retire the previous prediction *for that same market only*. A retry is safe:
it supersedes rather than duplicating.

### 7.2 Read current predictions for a match — `GET /api/v1/predictions/:id`

**`:id` is the match id** (see the warning above).

**Request:** no parameters, no body.

**Response `200`** — every **current** market for that match:

```json
{
  "match_id": 4280,
  "predictions": [
    { "market": "1x2", "selection": "H",
      "probabilities": { "H": 0.63552, "D": 0.27695, "A": 0.08753 },
      "model_version": "0.3.0", "generated_at": "2026-10-30T08:38:24Z" }
  ]
}
```

Each entry has exactly these keys: `market`, `selection`, `probabilities`,
`model_version`, `generated_at`.

Optional `?market=1x2` restricts to one market (invalid → `400`).

**Response `404`:**

```json
{ "error": "no current prediction for match 4280" }
```

Returned both when the match does not exist and when it exists but has no
current prediction. A completed match that was never predicted also returns 404
here.

**This is the endpoint to call to display predictions** — it never triggers
model work, so it is safe to call on every screen focus/refresh.

### 7.3 List stored predictions — `GET /api/v1/predictions`

**Query parameters:**

| Parameter | Type | Behaviour |
| --- | --- | --- |
| `match_id` | integer | Only this match. |
| `market` | enum | One of the four markets. Invalid → `400`. |
| `model_version` | string | Only this model version. |
| `include_history` | boolean | `true` includes superseded predictions. Default: current only. |
| `limit` | integer | `1..2000`, default 500; values `>2000` clamp, `<1` reset to 500; non-integer reset to 500. |

**Response `200`** — bare array, ordered by `generated_at` desc, `id` desc:

```json
[
  {
    "id": 24,
    "match_id": 4280,
    "market": "double_chance",
    "model_version": "0.3.0",
    "home_probability": 0.0,
    "draw_probability": 0.0,
    "away_probability": 1.0,
    "probabilities": { "1x": 0.91247, "x2": 0.36448, "12": 0.72305 },
    "selection": "1x",
    "most_likely_outcome": "away",
    "generated_at": "2026-10-30T08:38:24Z"
  }
]
```

> **Legacy fields.** `home_probability` / `draw_probability` /
> `away_probability` and `most_likely_outcome` exist for 1X2 compatibility only.
> **For any non-1X2 market they are meaningless** — note the example above: a
> double-chance row reports `away_probability: 1.0` and
> `most_likely_outcome: "away"` because those columns are the retired 1X2
> shape. **Always read `probabilities` and `selection`**, which are correct for
> every market.

---

## 8. Model status — `GET /api/v1/model_status`

Reports which model versions have produced **stored** predictions. It does not
ask the ML service whether a model is loaded, so it stays available when the ML
container is down.

**Request:** no parameters.

**Response `200`:**

```json
{
  "prediction_count": 64,
  "latest_generated_at": "2026-10-30T08:38:24Z",
  "model_versions": [
    { "model_version": "0.4.0", "prediction_count": 32,
      "first_generated_at": "2026-10-29T10:00:00Z",
      "latest_generated_at": "2026-10-30T08:38:24Z" }
  ]
}
```

Honest empty state before anything is predicted:
`{"prediction_count": 0, "latest_generated_at": null, "model_versions": []}`.

---

## 9. Synchronization status — `GET /api/v1/sync/status`

Operational health of the daily synchronization (fixtures and results), read from
the `sync_runs` ledger. **Read-only**: calling it never starts, retries or
modifies a run, so it is safe to poll.

**Request:** no parameters, no body.

**Response `200`:**

```json
{
  "status": "degraded",
  "checked_at": "2026-10-30T08:37:18Z",
  "schedules": {
    "fixtures": {
      "last_success_at": "2026-10-30T08:36:21Z",
      "last_attempt_at": "2026-10-30T08:36:09Z",
      "last_attempt": {
        "status": "succeeded",
        "trigger": "schedule",
        "duration_seconds": 11.8,
        "counts": { "fetched": 80, "created": 0, "updated": 0, "skipped": 80, "rejected": 0 },
        "error": null
      },
      "running": false,
      "stale": false,
      "stale_after_hours": 36,
      "schedule": {
        "cron": "30 3 * * *",
        "timezone": "UTC",
        "description": "Daily fixture synchronization (new fixtures, reschedules, postponements)",
        "next_run_at": "2026-10-31T03:30:00Z"
      }
    },
    "results": {
      "last_success_at": null,
      "last_attempt_at": null,
      "last_attempt": null,
      "running": false,
      "stale": true,
      "stale_after_hours": 36,
      "schedule": {
        "cron": "0 6 * * *",
        "timezone": "UTC",
        "description": "Daily completed-result synchronization and reconciliation",
        "next_run_at": "2026-10-31T06:00:00Z"
      }
    }
  }
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `status` | `"ok"` \| `"degraded"` | `ok` when **both** kinds are fresh; `degraded` when either is stale (including "never ran"). |
| `checked_at` | string | When this snapshot was produced (UTC). |
| `schedules` | object | Always exactly two keys: `fixtures`, `results`. |
| `last_success_at` | string \| null | Completion time of the most recent **successful** run; `null` if none. |
| `last_attempt_at` | string \| null | Start time of the most recent attempt, successful or not. |
| `last_attempt` | object \| null | `null` until the first attempt. |
| `last_attempt.status` | `"running"` \| `"succeeded"` \| `"failed"` | Outcome of that attempt. |
| `last_attempt.trigger` | `"schedule"` \| `"manual"` | Why it ran. |
| `last_attempt.duration_seconds` | number \| null | `null` while still running. |
| `last_attempt.counts` | object | `fetched`, `created`, `updated`, `skipped`, `rejected` — always all five integers. |
| `last_attempt.error` | string \| null | Redacted failure summary; `null` on success. Credentials are never present. |
| `running` | boolean | A run of this kind is open right now. |
| `stale` | boolean | No success within the last `stale_after_hours` (36). A failed attempt does **not** extend freshness. |
| `stale_after_hours` | integer | The staleness window in force. |
| `schedule` | object \| null | The published schedule for this kind. |
| `schedule.next_run_at` | string \| null | Next occurrence computed from the cron, in UTC. |

**Errors:** none in normal operation. If the database is unreachable this
endpoint fails like any other database-backed endpoint (5xx).

**No secrets.** Provider URLs, API keys and raw provider payloads are never
returned; `error` is stored already redacted (`apikey=[FILTERED]`).

**Intended mobile use:** a diagnostics screen. `status: "degraded"` means fixture
or result data may be out of date — show it as a data-freshness warning, not as a
hard error, because the API itself is still serving.

---

## CORS

`rack-cors` is installed and configured in
`backend/config/initializers/cors.rb`.

**Native React Native does not enforce CORS** — the app works with or without
this policy. It matters for `expo start --web` and any browser context.

| Environment | Allowed origins |
| --- | --- |
| development / test | `CORS_ORIGINS` if set, else `http://localhost:8081`, `http://127.0.0.1:8081`, `http://localhost:19006`, `http://127.0.0.1:19006` |
| production | **Only** `CORS_ORIGINS`. No default, no wildcard. |

Environment variable (comma-separated, scheme + host + optional port, no trailing
slash):

```bash
CORS_ORIGINS=http://localhost:8081,http://192.168.1.20:8081
```

- Allowed methods: `GET`, `POST`, `OPTIONS`, `HEAD`.
- Allowed headers: any requested header (`headers: :any`).
- `OPTIONS` preflight: answered automatically (`max_age: 600`).
- Credentials: **not** enabled. There is no cookie/auth surface.
- `*` is honoured in **development only** and ignored in production.

Verified live: a request with `Origin: http://localhost:8081` receives
`access-control-allow-origin: http://localhost:8081`; an unlisted origin receives
no CORS headers.

> CORS is **not** Docker network reachability. If the app cannot reach the API at
> all, check the host/port (Compose maps `127.0.0.1:3000`) and, on a device, that
> you are using the host's LAN IP rather than `localhost`.

---

## Quick reference for the mobile client

```ts
const BASE = 'http://localhost:3000';

// 1. Fetch a season's fixtures
GET  `${BASE}/api/v1/seasons?competition_id=4`
GET  `${BASE}/api/v1/matches?season_id=5&status=scheduled`

// 2. Ask for predictions for one match (match_id in the BODY)
POST `${BASE}/api/v1/predictions`
     body: { match_id: 4280, markets: ['1x2','over_under_2.5','btts','double_chance'] }
     -> 201 | 207 (partial) | 400 | 404 | 422 | 503

// 3. Read stored predictions for a match (path id IS the match id)
GET  `${BASE}/api/v1/predictions/4280` -> 200 | 404

// 4. Diagnostics
GET  `${BASE}/api/v1/health`
GET  `${BASE}/api/v1/ready`
GET  `${BASE}/api/v1/sync/status`
```

Rules of thumb:

1. `match_id` in the **body** for `POST`, in the **path** for `GET`.
2. Treat `207` as a normal outcome and render successful markets.
3. Read `probabilities` + `selection`, never the legacy
   `home_probability`/`away_probability` trio, for non-1X2 markets.
4. Never call the FastAPI service directly.
5. Names live in separate collections; matches carry ids only.
