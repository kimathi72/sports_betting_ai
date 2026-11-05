# Betting intelligence foundations — design (Phase D)

**Status: DESIGN ONLY. No odds ingestion, no betting execution, no financial logic
implemented. Nothing in this document has been built.**

## 1. The gap this closes

The project currently has **no odds data of any kind** — no table, no ingestion, no
margin handling, no expected value. Therefore no statement about betting value is
possible today, and none should be made. A model probability is not an edge; it is
one half of the comparison.

## 2. Odds ingestion

### 2.1 Provider requirements

| Requirement                     | Why                                                              |
| ------------------------------- | ---------------------------------------------------------------- |
| Historical **and** closing odds | closing-line value is the strongest cheap signal of skill        |
| Timestamped snapshots           | the only way to know what was available when a decision was made |
| Bookmaker identity              | margins and availability differ per book                         |
| Market + selection naming       | must map to our five markets unambiguously                       |
| Decimal odds                    | single representation; everything else derived                   |

**Candidates to evaluate (not selected):** The Odds API, Betfair historical, football-data.co.uk
closing odds. Each must be verified for coverage of our 11 competitions before adoption.

### 2.2 Storage

Append-only. Never update a snapshot, because the value of the data is that it records
what was available at a moment.

| Table               | Key columns                                                                                 |
| ------------------- | ------------------------------------------------------------------------------------------- |
| `odds_snapshots`    | `match_id`, `bookmaker`, `market`, `selection`, `decimal_odds`, `captured_at`, `is_closing` |
| `odds_capture_runs` | run id, source, matches covered, captured_at                                                |

Constraints: `decimal_odds > 1.0`; unique on (`match_id`, `bookmaker`, `market`,
`selection`, `captured_at`).

## 3. Margin and implied probability

For a market with selections _i_:

```
overround = Σ (1 / odds_i)
fair_probability_i = (1 / odds_i) / overround      # proportional (multiplicative) method
```

**Proportional is the default.** It is simple and conservative. Shin's method is a
better fit when favourite-longshot bias is expected, and should be evaluated as a
variant, not assumed superior.

### 3.1 Double Chance is not a distribution

Double Chance selections **overlap**: 1X and X2 both contain the draw. Therefore:

- `sum(1X, X2, 12) ≈ 2`, not 1 — margin removal must be applied to the **underlying
  1X2 market**, not to the DC selections directly;
- DC model probability is derived: `P(1X) = P(H) + P(D)`.

Treating DC as a three-way exclusive market would both corrupt the overround and
overstate edge. Any future implementation must assert `P(1X) == P(H) + P(D)` exactly.

## 4. Expected value

```
EV_per_unit = p_model × decimal_odds − 1
```

Where `p_model` is our calibrated probability for that selection, **after** the
calibration phase produces a validated calibrator. Using uncalibrated probabilities
here would propagate overconfidence directly into stake sizing.

Requirements before any EV is reported:

1. A fitted, validated calibrator on a disjoint assessment partition.
2. `p_model` bounded away from 0 and 1 (a probability of 0.999 produces absurd EV).
3. Odds captured **before** kickoff, with `captured_at` recorded.
4. The overround reported alongside, so a suspiciously generous price is visible.

A high model probability is **not** a value bet. Value requires `p_model × odds > 1`
with the odds actually obtainable.

## 5. Closing line value

```
CLV = (closing_implied_probability − our_entry_implied_probability) / our_entry_implied_probability
```

Reported as beat/miss rate over a sample. CLV is the most credible short-horizon
skill measure but requires a genuine closing snapshot; without one it cannot be
computed, and must not be approximated from the last odds we happened to see.

## 6. Backtesting limitations

| Limitation                           | Consequence                                                            |
| ------------------------------------ | ---------------------------------------------------------------------- |
| Historical odds are often incomplete | survivorship bias toward well-covered fixtures                         |
| Line movement is information         | a backtest using only closing odds cannot reproduce what was available |
| Our completed data is spent          | any backtest on it is exploratory by definition                        |
| Small samples                        | a 55% "win rate" on 100 bets is indistinguishable from noise           |
| Multiple comparisons                 | scanning many markets inflates apparent edges                          |

**A positive backtest must never be presented as evidence of future profitability.**

## 7. Staking and exposure (design constraint, not implemented)

- Flat staking first; any sizing model is a separate, later phase.
- Hard caps: max stake per bet, per day, per competition.
- No automated placement. Manual confirmation for every bet.
- A losing-streak circuit breaker that halts after a defined drawdown.

## 8. Paper trading

The correct next step after calibration, **before any real money**:

1. Issue predictions with real timestamps (prospective evaluation, Phase C).
2. Record would-be bets and stakes without placing them.
3. Score against results and closing odds.
4. Require the minimum samples in `prospective_evaluation_design.md` §8.

## 9. Minimum evidence before any real-money decision

| Requirement                                    | Threshold       |
| ---------------------------------------------- | --------------- |
| Prospective predictions evaluated              | ≥ 1,000         |
| Calibrated probabilities (disjoint assessment) | required        |
| Odds with closing snapshots                    | ≥ 1 full season |
| Positive CLV over sample                       | required        |
| Documented protocol digest                     | required        |

Below all of these, the system's output is **"insufficient evidence"**.

## 10. Implementation order (each requires separate approval)

1. Odds schema + ingestion for one competition, verifying coverage.
2. Margin removal with decomposition tests (DC overlapping).
3. Calibration (Phase B) fitted and validated.
4. EV reporting **without** staking.
5. Paper trading with real timestamps.
6. Only then, staking controls.
---

## 11. Paper-trading foundation: gap analysis and concrete plan (2026-11-04)

**Nothing below is implemented, and no provider has been contacted, registered or
paid for.** This section records what is missing, what can safely be built next, and
in which order, so the work is not re-invented later.

### 11.1 Gap matrix — design requirement vs. what exists

| Requirement | Design §  | Exists today | Gap |
| --- | --- | --- | --- |
| Decimal odds representation | 2.1 | — | none (new) |
| Odds snapshots, append-only | 2.2 | — | entire table + writer |
| Bookmaker identity | 2.2 | — | column + catalogue |
| Overround computation | 3 | — | pure function + tests |
| Margin removal (proportional) | 3 | — | pure function; Double Chance must be excluded (see 11.3) |
| Expected value | 4 | — | pure function over (model p, fair odds) |
| Closing line value | 4 | — | requires `is_closing` snapshot |
| Market comparison | — | — | per-book view of the same snapshot |
| Paper trading ledger | 8 | — | table + scorer; **must reuse** `ProspectiveEvaluationRecord` semantics |
| Exposure / risk caps | 7 | — | policy object, no automation |
| Prospective predictions | C1/C2 | **live** | — |
| Calibrated probabilities | C1 | infrastructure only | fitting still blocked |

The single most important observation: **nine of the eleven rows need no new
evidence**, only code, whereas a calibrated probability and closing odds are both
*data* problems that take a season to fill. Code can be written and tested now
against synthetic fixtures without claiming anything about profitability.

### 11.2 Provider assessment (desk research only — no account, no key)

| Provider | Coverage of our 11 leagues | Historical closing odds | Cost shape | Verdict |
| --- | --- | --- | --- | --- |
| football-data.co.uk (CSV, closing odds columns) | all 11, same source as our historical results | yes, per match | free | **best first step for retrospective research**; no live snapshots |
| The Odds API | broad, but keyed by its own sport/league names | limited history on the free tier | paid tiers | candidate for **live snapshots**; needs a mapping table and approval |
| Betfair historical (historical stream) | UK/IE strong, European coverage partial | yes, with timestamps | paid, account + licence | candidate only if a real-money phase is ever considered |

**Recommendation:** football-data.co.uk first. It requires no account, it is the same
provider that already backs our historical results (so identity reconciliation is
already solved), and it answers the only question that matters at this stage —
*are the model's probabilities closer to the market's than chance?* — without any
live integration. A live, timestamped provider is required only for CLV and paper
trading, and should not be selected until the retrospective comparison shows
something worth timestamping.

**Caveat, stated plainly:** retrospective odds cannot produce a betting claim. The
matches are already spent, and §17 of the handover establishes that every completed
match is spent. Retrospective odds can only be used as *diagnostics* — a
calibration-against-market check — and any number derived from them is exploratory.

### 11.3 One design correction, recorded before implementation

The design (§3) says margin removal is proportional across selections. That is
correct for 1X2, O/U and BTTS. **It must not be applied to Double Chance**, because
1X and X2 overlap: the three selections form a 2-of-3 system, not a partition, so
`Σ 1/odds` is not an overround and dividing by it would produce "fair" probabilities
that sum to 2 and are individually wrong. Double Chance fair probabilities must be
derived from the *de-vigged 1X2*: `P(1X) = P(H) + P(D)`.

The same rule already governs the model side (Double Chance is derived, never
trained), so the model and the market must be compared on the same construction.
A unit test must pin this; it is the kind of error that silently inflates EV.

### 11.4 Implementation order (each step independently reviewable)

| # | Step | Depends on | Risk |
| --- | --- | --- | --- |
| 1 | `OddsSnapshot` table + append-only writer + `is_closing` flag | — | low, additive migration |
| 2 | Pure functions: `overround`, `de_vig`, `ev`, `clv`, with the Double Chance exception | 1 | low; no I/O |
| 3 | football-data odds importer (historical, idempotent, dry-run by default) | 1–2 | low; same reconciliation path as results |
| 4 | Retrospective market-vs-model diagnostic (log loss of model vs. de-vigged market) | 3 | **reporting only**; explicitly exploratory |
| 5 | Paper-trading ledger: would-be bets recorded with a snapshot reference | 1–3 | low writes, no money |
| 6 | Risk-caps policy object (max stake/day/competition, drawdown halt) | 5 | policy only |
| 7 | Live odds provider decision | 4 shows something | needs approval + budget |

Steps 1–2 are safe to build now and are pure additions. Step 3 needs approval to
download data (no account required). Steps 5+ must wait until there is prospective
evidence to bet on — otherwise the ledger records hindsight.

### 11.5 What remains a genuine blocker

1. **Calibrated probabilities.** Without them, EV is computed from uncalibrated
   numbers and its sign is meaningless. Fitting is still not authorised.
2. **Prospective sample.** §10.3: zero qualifying predictions today.
3. **A holdout.** Everything completed is spent; only post-freeze matches count.

Until 1–3 are satisfied: **INSUFFICIENT EVIDENCE — NO BETTING RECOMMENDATION.**

---

## 12. Phase D1 — odds findings and paper-trading implementation plan (2026-11-04)

**No odds were ingested. No provider was selected or paid for. No bet was placed.**
This section records what was measured, what was built, and what remains gated.

### 12.1 football-data.co.uk — measured, not assumed

Fetched directly on 2026-11-04 (`https://football-data.co.uk/mmz4281/2627/<CODE>.csv`):

| Competition | Rows | With pre-match odds | With closing odds | Last row |
| --- | ---: | ---: | ---: | --- |
| E0 Premier League | 110 | 110 | 110 | 2026-11-02 |
| E1 Championship | 160 | 160 | 160 | 2026-11-02 |
| SC0 Scottish Premiership | 40 | 40 | 40 | 2026-11-01 |
| SP1 La Liga | 110 | 110 | 110 | 2026-11-02 |
| D1 Bundesliga | 90 | 90 | 90 | 2026-11-02 |
| I1 Serie A | 100 | 100 | 100 | 2026-11-02 |
| F1 Ligue 1 | 100 | 100 | 100 | 2026-11-02 |
| N1 Eredivisie | 90 | 90 | 90 | 2026-11-01 |
| B1 Belgian Pro League | 100 | 100 | 100 | 2026-11-01 |
| P1 Primeira Liga | 90 | 90 | 90 | 2026-11-02 |
| T1 Super Lig | 90 | 90 | 90 | 2026-11-02 |

**All 11 target competitions are covered, free, with no account.**

| Question | Answer |
| --- | --- |
| Which markets? | 1X2 and Over/Under 2.5, per bookmaker. **No BTTS, no Double Chance, no Correct Score.** |
| Which bookmakers? | 1X2: B365, BW, BF, BM, BV, CL, LB, PS, P, WH, Max, Avg. O/U 2.5: B365, BW, PS, P, Max, Avg. |
| Opening or closing? | **Both.** `B365H/D/A` is the pre-match price; `B365CH/CD/CA` is the closing price. |
| Pre-match? | Yes — the file is a pre-match snapshot, not in-play. |
| Timestamp? | **No.** The file records a date, not a capture time. This is the single most important limitation (12.2). |
| Suitable for prospective paper trading? | **Not on its own.** Suitable for a retrospective diagnostic and for closing-line reference. |

### 12.2 The limitation that decides the architecture

football-data.co.uk publishes **one pre-match snapshot and one closing snapshot per
match, with no capture timestamp**. That means:

- it **cannot** prove what price was available at the moment a prediction was issued;
- it **cannot** support a genuine paper-trading ledger, because a paper bet needs a
  price that provably existed before kickoff and before the result;
- it **can** support a retrospective diagnostic (model vs. de-vigged market) and a
  closing-line reference for bets taken elsewhere.

**Therefore: historical odds coverage is NOT live odds availability.** A live,
timestamped provider is required before paper trading can produce evidence, and that
provider has not been selected.

### 12.3 What was built (pure, tested, no I/O)

| Component | File | Purpose |
| --- | --- | --- |
| `Odds::OddsMath` | `app/services/odds/odds_math.rb` | overround, de-vig, EV, CLV, decimal-odds validation |
| `Odds::MarketMatching` | `app/services/odds/market_matching.rb` | provider names → our markets; football-data column families |
| `Odds::PaperBet` | `app/services/odds/paper_bet.rb` | immutable would-be bet, settlement, portfolio summary |

These are deliberately **not** ActiveRecord models. Nothing is persisted, so no
schema change was needed and no odds data entered the database.

**The Double Chance rule is enforced in code, not just documented.** `de_vig` raises
`NotAPartition` for a Double Chance market, and infers the market from the selection
keys so a caller that forgets to pass `market:` cannot get a silently normalised
result. Double Chance fair probabilities must be derived from the de-vigged 1X2.

### 12.4 Implementation plan (each step needs approval)

| # | Step | Depends on | Gate |
| --- | --- | --- | --- |
| 1 | `odds_snapshots` table (append-only, `captured_at`, `is_closing`, `bookmaker`, `market`, `selection`, `decimal_odds`) | — | migration approval |
| 2 | football-data odds importer (historical, idempotent, dry-run default) | 1 | data-download approval |
| 3 | Retrospective diagnostic: model log loss vs. de-vigged market log loss, per competition | 2 | **reporting only, exploratory** |
| 4 | Live timestamped provider selection | 3 shows something | **budget + account approval** |
| 5 | Paper-bet ledger table referencing a snapshot id | 1, 4 | migration approval |
| 6 | Exposure policy object (max stake/day/competition, drawdown halt) | 5 | policy review |
| 7 | Settlement job reusing `ProspectiveEvaluation` semantics | 5 | scheduling approval |

Steps 1–3 are safe and cheap. Step 4 is the real gate: without a timestamped price
there is no paper trading, only a backtest.

### 12.5 Sample-size requirements (unchanged, restated)

| Requirement | Threshold |
| --- | --- |
| Prospective predictions evaluated | ≥ 1,000 |
| Distinct competitions | ≥ 3 |
| Time span | ≥ 3 months |
| Per-competition n | ≥ 200 |
| Calibrated probabilities (disjoint assessment) | required |
| Closing snapshots | ≥ 1 full season |
| Positive CLV over the sample | required |

Current prospective evidence: **0**. See `docs/prospective_evaluation_design.md` §10.3.

**INSUFFICIENT EVIDENCE — NO BETTING RECOMMENDATION.**
