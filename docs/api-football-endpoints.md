# API-Football v3 — endpoint catalogue and account capabilities

Verified against the live account on 2026-10-30. Base URL:
`https://v3.football.api-sports.io` (configured as a bare host in
`backend/.env`; `Import::ApiFootballClient` normalises it to https).

Authentication: `x-apisports-key: <key>` header. **Never** a query parameter.
The key is read from `API_FOOTBALL_API_KEY` at request time and is never stored
on the client object, so it cannot leak through `inspect` or a log line.

## Account capabilities (measured, not assumed)

| Capability                | Result                                                       |
| ------------------------- | ------------------------------------------------------------ |
| Plan                      | **Free**                                                     |
| Requests/day              | **100**                                                      |
| Rate limit (burst)        | 10/minute                                                    |
| Remaining at last check   | 97                                                           |
| `/status`                 | Accessible (returns an object, not a list)                   |
| `/leagues/seasons`        | Accessible                                                   |
| `/leagues?current=true`   | Accessible                                                   |
| `/fixtures?league&season` | Accessible **seasons 2022–2024 only**                        |
| `/fixtures?live=all`      | **Accessible** — 41 live fixtures at time of test            |
| `/teams?league&season`    | Accessible                                                   |
| Season 2025, 2026         | **BLOCKED** — `Free plans do not have access to this season` |
| Odds, statistics, events  | Not verified / not required for the current milestone        |

### Practical request budget

| Task                                        | Requests                                  |
| ------------------------------------------- | ----------------------------------------- |
| Fixture sync, one league-season             | 1                                         |
| Daily fixture sync (all configured seasons) | 2–3                                       |
| Daily result sync                           | covered by the same fixtures call         |
| Live polling                                | 1 per poll, returns **all** live fixtures |
| Team mapping (one-off)                      | 1                                         |

At 100 requests/day the live poll interval is the binding constraint. A 5-minute
interval limited to 12:00–22:55 UTC costs up to 132 requests/day if run all day,
which is why the schedule is windowed and the job skips when nothing is live.
**Recommended sustainable cadence: one poll every 5 minutes during match hours**,
yielding roughly 36 requests per match day and leaving room for the daily syncs.

## Endpoint reference

Every endpoint below uses **GET** and returns:

```json
{ "get": "...", "parameters": {...}, "errors": [], "results": 0, "paging": {...}, "response": [] }
```

`errors` is `[]` on success, or an object (e.g. `{"plan": "..."}`). A **200 with a
populated `errors` object is a failure** — the client raises `ApiError`, so an
empty import is never reported as a successful one.

| Endpoint               | Params                                                                                               | Returns                       | Pagination                  | Notes                                                        |
| ---------------------- | ---------------------------------------------------------------------------------------------------- | ----------------------------- | --------------------------- | ------------------------------------------------------------ |
| `/status`              | —                                                                                                    | Account object (plan, quotas) | n/a                         | `response` is an object; the client wraps it in a list       |
| `/timezone`            | —                                                                                                    | Timezone list                 | No                          | Not used                                                     |
| `/countries`           | `name`, `code`, `search`                                                                             | Countries                     | No                          | Supplementary                                                |
| `/leagues`             | `id`, `name`, `country`, `season`, `team`, `current`, `search`                                       | League + seasons + coverage   | No                          | Use to discover league ids and season availability           |
| `/leagues/seasons`     | —                                                                                                    | Accessible years              | No                          | Confirms plan boundaries                                     |
| `/teams`               | `id`, `name`, `league`, `season`, `country`, `search`                                                | Teams + venue                 | **Yes**                     | Used for team mapping                                        |
| `/fixtures`            | `id`, `ids`, `live`, `date`, `league`, `season`, `team`, `from`, `to`, `status`, `round`, `timezone` | Fixtures                      | **Yes** (multi-league/date) | Primary ingestion endpoint                                   |
| `/fixtures/rounds`     | `league`, `season`, `current`                                                                        | Round names                   | No                          | Not used                                                     |
| `/fixtures/headtohead` | `h2h`, `last`                                                                                        | Past meetings                 | No                          | Not implemented (no contract in our API)                     |
| `/fixtures/events`     | `fixture`, `league`, `team`, `player`, `type`                                                        | Goal/card/sub events          | No                          | One request per fixture — quota-prohibitive, not implemented |
| `/fixtures/statistics` | `fixture`, `league`, `team`, `type`                                                                  | Match statistics              | No                          | Same cost concern                                            |
| `/fixtures/lineups`    | `fixture`, `league`, `team`                                                                          | Lineups                       | No                          | Not implemented                                              |
| `/fixtures/players`    | `fixture`, `league`, `team`                                                                          | Per-player stats              | No                          | Not implemented                                              |
| `/standings`           | `league`, `season`, `team`                                                                           | League table                  | No                          | Not implemented                                              |
| `/injuries`            | `league`, `season`, `fixture`, `date`, `team`                                                        | Injuries                      | No                          | Not implemented                                              |
| `/odds`, `/odds/live`  | —                                                                                                    | Betting odds                  | —                           | Out of scope                                                 |

## Fixture status codes (mapped in `Import::ApiFootballAdapter`)

| Provider                                         | Internal      | Training label?                      |
| ------------------------------------------------ | ------------- | ------------------------------------ |
| `FT`, `AET`, `PEN`                               | `completed`   | **Yes**                              |
| `1H`, `HT`, `2H`, `ET`, `BT`, `P`, `SUSP`, `INT` | `in_progress` | **No** — score deliberately stripped |
| `PST`                                            | `postponed`   | No                                   |
| `CANC`, `ABD`, `AWD`, `WO`                       | `cancelled`   | No                                   |
| `NS`, `TBD`                                      | `scheduled`   | No                                   |

Any other code yields no status and the row is rejected rather than guessed.

## Score handling

- Regulation score is stored in `home_score`/`away_score` **only** for
  `FT`/`AET`/`PEN`, and only when both goals are present.
- Live scores are **never** written as final results — the adapter strips them
  for any non-completed status, so an in-progress match cannot become a label.
- Extra time and penalty breakdown (`score.extratime`, `score.penalty`) are
  **not** stored: the schema has no columns for them, and folding them into
  regulation scores would corrupt every model trained on the result. Adding them
  needs a migration and is left as documented work.
