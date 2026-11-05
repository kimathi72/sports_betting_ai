# ESPN multi-competition team mapping and fixture synchronization

One workflow for every ESPN competition. Adding a league is configuration, not code.

## 1. Architecture

```
EspnLeagueCoverage::VERIFIED   code -> slug        (configuration)
        |
Sync::EspnCompetitionPlan      competition + season + clubs + evidence
        |
Import::EspnTeamIdentity       provider team id -> canonical Team   (pure)
        |
Import::ReconciliationPreview  what an import WOULD do              (no writes)
        |
Sync::EspnCoverageSurvey       the loop, one competition at a time   (isolation)
```

Every stage already existed in some form except the last three; the reconciler,
adapter and `ExternalIdentifier` model are reused unchanged.

### Where the old one-league limitation lived

`espn:map_teams` printed a free-text `unmapped` list and wrote nothing for those
clubs, and the SP1 work that followed was a hand-written script per league. The
limitation was never in the adapter — it was that identity decisions had no home.
`Import::EspnTeamIdentity` is that home: it takes the club list as an argument.

## 2. Configuration

| Code | Slug    | Competition          |
| ---- | ------- | -------------------- |
| SC0  | `sco.1` | Scottish Premiership |
| SP1  | `esp.1` | La Liga              |
| D1   | `ger.1` | Bundesliga           |
| I1   | `ita.1` | Serie A              |
| F1   | `fra.1` | Ligue 1              |
| N1   | `ned.1` | Eredivisie           |
| B1   | `bel.1` | Belgian Pro League   |
| P1   | `por.1` | Primeira Liga        |
| T1   | `tur.1` | Turkish Super Lig    |

Slugs come from `EspnLeagueCoverage::VERIFIED` — the single source, already verified
against live ESPN. **The catalogue code and the provider slug are never
interchangeable**; confusing them is what caused the original E0/E1 contamination.

```ruby
plan = Sync::EspnCompetitionPlan.for_code("SP1", season_name: "2026/27")
plan.slug             # "esp.1"
plan.canonical_clubs  # the 20 clubs that played in that season
plan.evidence         # documented aliases (usually empty)
```

Canonical clubs are **season-scoped**: a club relegated three seasons ago is not part
of the current league and is not a mapping candidate.

## 3. Identity resolution

Ordered ladder, from `Import::EspnTeamResolver` (unchanged):

| Rule                  | Example                               | Basis                          |
| --------------------- | ------------------------------------- | ------------------------------ |
| identical key         | `Arsenal` = `Arsenal`                 | `:exact`                       |
| same words, any order | `city manchester` = `manchester city` | `:exact`                       |
| one word abbreviated  | `Man City` ~ `Manchester City`        | `:exact`                       |
| shared head word      | `Sheffield` ~ `Sheffield United`      | `:exact`, refused if ambiguous |

Anything the ladder cannot reach is supplied by a human in
`EspnAliasEvidence`, keyed by competition, and recorded as `:evidence`:

```ruby
"SP1" => {
  "atletico madrid" => { canonical: "Ath Madrid", basis: "results match on identical dates, opponents and scores" },
  "Deportivo"       => { canonical: "La Coruna",  basis: "..." }
}
```

Evidence is keyed by the **normalised** name, so `Atlético Madrid` is found under
`atletico madrid`. A wrong or stale alias is reported as ambiguous, never silently
ignored.

### Outcomes

| Outcome                   | Meaning                                    | Persisted?  |
| ------------------------- | ------------------------------------------ | ----------- |
| `:existing`               | already mapped, and it agrees              | no change   |
| `:verified` / `:exact`    | one candidate, by rule                     | on approval |
| `:verified` / `:evidence` | one candidate, by human evidence           | on approval |
| `:ambiguous`              | two or more candidates                     | **never**   |
| `:conflict`               | provider id already mapped to another club | **never**   |
| `:unmapped`               | no candidate                               | **never**   |
| `:invalid`                | no usable provider id                      | **never**   |

## 4. Preview (mandatory before any write)

`Import::ReconciliationPreview` classifies rows using the reconciler's identity rules
— provider fixture id first, then `(home, away, calendar day)` — and never calls the
reconciler's write methods (`create_match`, `update!`, `record_mapping`).

Reported: events, `resolved`, `part_resolved`, `unresolved`, `invalid`, `existing`,
`would_create`, `conflicts`, and per-row detail including status and season conflicts.

**Proposed-but-unpersisted mappings** are passed in through `team_index:`, so a dry
run of a proposal is honest. Without it the preview saw only database mappings and
reported `resolved=0` — the bug this was written to fix.

**Zero-write guarantee** is enforced by spec: `Match.create!`,
`Match#update!` and `ExternalIdentifier.find_or_create_by!` are stubbed to raise, and
counts are asserted unchanged.

## 5. Commands

```bash
# Everything below is READ-ONLY.
docker compose exec -T web bundle exec rake espn:survey
docker compose exec -T web env CODES=SP1 SEASON=2026/27 FROM=20261101 TO=20261231 \
  bundle exec rake espn:survey
```

Adding a competition: add it to `EspnLeagueCoverage::VERIFIED` (already done for all
nine) and, only if some names share no lexical evidence, an entry in
`EspnAliasEvidence`.

## 6. Coverage after the survey (2026-11-01 .. 2026-12-31)

| Competition | Clubs | ESPN | Verified | Existing | Ambiguous | Unmapped | Resolved events | Would create |
| ----------- | ----: | ---: | -------: | -------: | --------: | -------: | --------------: | -----------: |
| SC0         |    12 |   12 |       12 |        0 |         0 |        0 |              47 |           47 |
| SP1         |    20 |   20 |       20 |        0 |         0 |        0 |              66 |           66 |
| D1          |    18 |   18 |       17 |        0 |         0 |        1 |              60 |           60 |
| I1          |    20 |   20 |       20 |        0 |         0 |        0 |              65 |           65 |
| F1          |    18 |   18 |       17 |        0 |         0 |        1 |              60 |           60 |
| N1          |    18 |   18 |       18 |        0 |         0 |        0 |              51 |           51 |
| B1          |    16 |   16 |       14 |        0 |         0 |        2 |              45 |           45 |
| P1          |    18 |   18 |       13 |        0 |         0 |        5 |              28 |           28 |
| T1          |    18 |   18 |       12 |        0 |         0 |        6 |              27 |           27 |

Unresolved names are real naming gaps (`Braga` vs `SC Braga`, `Istanbul Basaksehir`
vs `Basaksehir`), not algorithm failures. They are reported, never guessed.

## 7. Remaining work

1. Persist approved mappings (pending original approval).
2. Run `espn:discover` per competition once mapped.
3. Resolve the 15 unmapped clubs by adding evidence entries.

## 8. Tests

```
espn_team_identity_spec          9 examples
reconciliation_preview_spec      8 examples
espn_competition_plan_spec       8 examples
espn_coverage_survey_spec        4 examples
full suite                    1110 examples, 0 failures, 1 pending
```
