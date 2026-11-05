# Football data providers — provenance, strategy and reconciliation

Audited and tested 2026-10-30.

## 1. What we already have (provenance)

Every match in the database has a `football_data` ExternalIdentifier. That is the
**canonical historical source**: football-data.co.uk season CSVs, imported via
`Import::FootballDataCoUkAdapter` → `MatchImporter`.

| Season  | Matches | Status                         | Provider                       | Notes                                                 |
| ------- | ------- | ------------------------------ | ------------------------------ | ----------------------------------------------------- |
| 2023/24 | 380     | 380 completed                  | football_data                  | Correct, complete                                     |
| 2024/25 | 380     | 380 completed                  | football_data (+ api_football) | Correct; API-Football mappings added as a cross-check |
| 2025/26 | 381     | 380 completed, **1 scheduled** | football_data                  | **380 real + 1 duplicate**                            |
| 2026/27 | 80      | 80 completed                   | football_data                  | **Correct but incomplete: first 8 rounds only**       |

### The 381st fixture in 2025/26 — a duplicate

Match **4280** (Arsenal v Chelsea, 2026-12-26, `scheduled`) is a **second copy**
of a fixture already present in the season on 2026-03-01. It is the only match
in that season with no `football_data` identifier.

It is also the cause of the mobile dashboard anomaly: the app reported "381
fixtures, 1 remaining" because this stray row sat in the future while every real
2025/26 match had been played. **It is not a sync bug and not real data.**

_Recommendation: delete match 4280 after verification. Not done here — this task
forbids deleting historical records._

### The 80 matches in 2026/27 — real, but truncated

All 80 are genuine, verified completed results for **rounds 1–8** (2026-08-21 →
2026-10-25). The competition composition is correct: the 2026/27 promoted clubs
(Coventry, Ipswich, Hull) and relegated clubs (West Ham, Burnley, Wolves) match
the real season exactly.

**What was missing: rounds 9+ (fixtures beyond 2026-10-25).** That is the gap
this phase closes.

## 2. Provider comparison (tested, not assumed)

| Provider                | Key needed      | 2026/27 fixtures           | Live    | Rate limit    | Notes                                   |
| ----------------------- | --------------- | -------------------------- | ------- | ------------- | --------------------------------------- |
| **football-data.co.uk** | No              | CSV only, season-end       | No      | n/a           | Canonical history; no upcoming fixtures |
| **API-Football (free)** | Yes             | **BLOCKED** (2022–24 only) | Yes     | 100/day       | Current via paid tier only              |
| **ESPN scoreboard**     | **No**          | **Yes — verified**         | **Yes** | None observed | 5 leagues tested                        |
| OpenLigaDB              | No              | German only                | Partial | None          | Not suitable as primary                 |
| football-data.org       | Yes (free tier) | Limited on free            | No      | 10/min        | Not tested with a key                   |
| Kaggle / GitHub CSVs    | n/a             | No                         | No      | n/a           | Static history only                     |

ESPN leagues verified with a real request: `eng.1`, `esp.1`, `ger.1`, `ita.1`,
`fra.1`, `uefa.champions`.

## 3. Chosen combination

| Need                              | Provider                                          |
| --------------------------------- | ------------------------------------------------- |
| Historical training data          | **football-data.co.uk** (existing)                |
| Current-season fixtures & results | **ESPN**                                          |
| Upcoming fixtures                 | **ESPN**                                          |
| Live status & scores              | **ESPN** (API-Football retained as a cross-check) |
| Canonical identity                | our own `Competition`/`Season`/`Team`/`Match`     |

**Cost: zero.** No paid tier is required for any of the six objectives.

## 4. Reconciliation policy

`Import::ApiFootballReconciler` is **provider-agnostic**: it resolves teams and
fixtures through the `provider` field on the row, so one reconciler serves every
source. This is the single write path — a second one would duplicate the rules
that must stay correct.

1. **Identity.** Resolve by `(provider, external_id)`, else by
   `(home_team, away_team, same calendar day)`.
2. **Completed results are authoritative.** A stored completed result is never
   overwritten by a different score from _any_ provider. A disagreement is
   counted as a `conflict` and the stored value stands.
3. **No completed match is ever downgraded** to scheduled/postponed.
4. **Live scores never become results.** Both adapters strip the score from any
   non-completed status, so an in-progress match cannot enter training data.
5. **Teams are never auto-created.** An unmapped provider team is `rejected` and
   reported, because a guessed identity creates duplicates that cost far more
   than a missing mapping.
6. **Provenance is permanent.** Every row keeps its provider identifier;
   re-importing adds a mapping rather than replacing one.

### 4a. How a bled fixture is identified (repair rule)

A fixture can be written into the wrong season (`espn:discover` resolved the
season by name, and several competitions share a season name). Removing the wrong
rows safely needs a signature real rows cannot satisfy. Date and club are not
enough — bled rows fall inside the season window and promoted/relegated clubs
appear in both divisions. The classifier that does work is **impossible
timestamps**, applied only to ESPN-only rows:

| Condition | Why it cannot match a real row |
|---|---|
| kickoff is not a plausible football slot (02:00, 03:00, 04:00 … UTC) | no European league kicks off at those hours |
| status is `completed` for a match that has not kicked off yet | a result cannot exist in the future |

Both are facts about the row, not guesses about names. A candidate must also
carry an ESPN identifier and no football-data identifier, so the canonical
history is never in scope. See `Sync::ForeignFixtureBleed`.

## 5. Known team-name divergences

Our canonical names come from the CSVs (`Man United`, `Nott'm Forest`,
`Tottenham`, `Man City`). Providers use full names. Mapping uses
`Team.normalize`, with explicit entries where the short form is genuinely
different. **No fuzzy matching**: it silently merges distinct clubs.

## 6. Live ingestion status

Discovered live fixtures: **40–43** via API-Football, **0 matched internally**
(all are foreign leagues we do not hold). ESPN matching to our own fixtures is
**verified working**: 5 real 2026/27 fixtures matched with correct scores.

**Live end-to-end (a match in progress updating our own record) is not yet
demonstrated**, because no Premier League match we hold was in play during
testing. The code path is unit-tested; see the report for the label.
