# ML System Audit — Sports Betting AI

**Date:** 2026-11-02
**Mode:** read-only. No training, no promotion, no code change, no DB write.
**Environment:** Docker-pinned `ml` container, `/app/ml` (repo mounted) + `/app/artifacts` (separate volume).

---

## 1. Executive summary

**Is the ML system capable of producing predictions?** **YES — VERIFIED.** All five markets
return valid probabilities end-to-end through Rails → FastAPI → Postgres for match 4357.

**Which markets work end-to-end?** All five: 1X2, Over/Under 2.5, BTTS, Double Chance
(derived, overlapping), Correct Score (top-6 truncated view of a full grid).

**Are the probabilities trustworthy enough for evaluation or betting?**
**For evaluation: PARTIALLY VERIFIED. For betting: NO.** The model is better than the
frequency baseline on log loss, but **there is no odds data anywhere in the project**
(no table, no ingestion, no margin removal, no EV calculation), so no betting claim can
be substantiated. Probabilities are **not calibrated** — calibration is measured, not applied.

**Is there a valid independent holdout?** **NO.** The project's own protocol file declares
the test partition contaminated: _"the test partition was already scored by an earlier
version of this harness … It is therefore NOT an untouched final holdout."_

**Biggest blocker:** no untouched holdout, combined with no odds data. The system cannot
currently produce a defensible out-of-sample quality estimate.

**Shortest safe path:** freeze the current generation, wait for genuinely new completed
matches to accumulate as a fresh holdout, and evaluate once, without re-tuning on it.

---

## 2. Actual repository / runtime state

| Item                    | Finding                                                                                                                            | Status   |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | -------- |
| Branch                  | `main`, uncommitted work                                                                                                           | VERIFIED |
| Modified files          | 37                                                                                                                                 | VERIFIED |
| Untracked files         | 95 (incl. `ml/app/*` modules)                                                                                                      | VERIFIED |
| ML modules present      | `features_v2.py`, `goal_models.py`, `eval_pipeline.py`, `train_markets.py`, `market_inference.py`, `elo.py`, `evaluate_markets.py` | VERIFIED |
| `ml/artifacts/` in repo | exists, populated                                                                                                                  | VERIFIED |
| Runtime artifacts       | `/app/artifacts` — **separate volume**, contents match repo                                                                        | VERIFIED |
| ML service              | `/health` 200, `/ready` ok                                                                                                         | VERIFIED |

**Resolving the previous contradiction:** earlier reports disagreed on whether
`features_v2.py`, `goal_models.py`, `eval_pipeline.py`, Dixon-Coles and multi-market
code existed. **All exist in the current checkout.** The disagreement was a stale
report, not a missing implementation.

---

## 3. Historical data quality

| Metric                                                |  Value | Status   |
| ----------------------------------------------------- | -----: | -------- |
| Completed matches (DB)                                | 39,288 | VERIFIED |
| Kicked off after final training cut (2025-02-26)      |  5,920 | VERIFIED |
| Training rows used by published models                | 33,368 | VERIFIED |
| Partition check `33,368 + 5,920 = 39,288`             |  exact | VERIFIED |
| Missing scores among completed                        |      0 | VERIFIED |
| Completed after training _run_ timestamp (2026-11-01) |      1 | VERIFIED |
| Scheduled rows carrying a score                       |      0 | VERIFIED |

Outcome distribution (completed):

| Outcome  |  Count |
| -------- | -----: |
| Home win | 17,143 |
| Draw     |  9,205 |
| Away win | 12,940 |

Scheduled fixtures are **correctly excluded** from labels: `features_v2` sets
`label_1x2 = None` unless `_completed(row)` (`features_v2.py:388-395`).

**Effect of the recent fixture expansion (39,976 → 41,970 matches):** none on training.
Only +1 completed match arrived; the 1,994 inserts were scheduled fixtures with no labels.
Training and evaluation queries are unaffected.

---

## 4. Feature engineering and leakage

**Feature version `v2`, 53 features** (`artifacts/model_1x2.joblib.meta.json`).

### Verified leakage-safe construction

The strongest evidence is the implementation, not the test names:

| Mechanism                                       | Evidence                                  | Status   |
| ----------------------------------------------- | ----------------------------------------- | -------- |
| Features computed **before** any state mutation | `features_v2.py:332-396` then `:397-419`  | VERIFIED |
| History appended only after use                 | `features_v2.py:397-399`                  | VERIFIED |
| All history filtered to strictly-before kickoff | `features.py:191` (`kickoff < current`)   | VERIFIED |
| Non-completed rows excluded from history        | `features.py` completed filter            | VERIFIED |
| State keyed per `(competition_id, team_id)`     | `features_v2.py:304, 322-325`             | VERIFIED |
| Merged history de-duplicated by match id        | `_merge_history` `features_v2.py:444-480` | VERIFIED |

**Same-kickoff handling:** history is appended per row in stable order, and the v1
helper filters `kickoff < current`, so a simultaneous kickoff is excluded from the
other's history. Verified by `test_simultaneous_kickoffs_do_not_leak_into_each_other`.

**Truncation test** (`test_truncating_the_dataset_does_not_change_earlier_vectors`)
proves past features do not depend on future rows.

### Residual risks

| Risk                                  | Assessment                                                                        | Status                                                                   |
| ------------------------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Elo initialisation                    | fixed prior (1500), no target-derived prior                                       | VERIFIED safe                                                            |
| Draw-rate prior                       | computed online from seen matches                                                 | VERIFIED safe                                                            |
| Preprocessing fitted outside training | v2 uses no scaler/imputer; the model consumes raw diffs                           | PARTIALLY VERIFIED — no scaler exists, so nothing can be fitted globally |
| Cold-start clubs                      | flagged `is_cold_start`, not imputed                                              | VERIFIED                                                                 |
| Season boundaries                     | no season-reset of Elo; cross-season continuity is a _design choice_, not leakage | VERIFIED                                                                 |

**No confirmed leakage found.**

---

## 5. Market implementation matrix

| Market        | Feature eng. | Training           | Evaluation | Inference | Artifact      | Rails | Contract                      | Status   |
| ------------- | ------------ | ------------------ | ---------- | --------- | ------------- | ----- | ----------------------------- | -------- |
| 1X2           | yes          | yes                | yes        | yes       | yes           | yes   | sums to 1                     | VERIFIED |
| O/U 2.5       | yes          | yes                | yes        | yes       | yes           | yes   | sums to 1                     | VERIFIED |
| BTTS          | yes          | yes                | yes        | yes       | yes           | yes   | sums to 1                     | VERIFIED |
| Double Chance | derived      | **none** (correct) | yes        | derived   | uses 1X2/grid | yes   | **sums to 2.0** (overlapping) | VERIFIED |
| Correct Score | grid         | goal model         | yes        | derived   | goal model    | yes   | top-6 **truncated view**      | VERIFIED |

Live check, match 4357:

```
1x2             sum=1.0000
over_under_2.5  sum=1.0000
btts            sum=1.0000
double_chance   sum=2.0000   <- overlapping events, not a distribution
correct_score   sum=0.3563   <- top 6 of a full grid, truncated by design
```

Double Chance has **no independently trained model** — confirmed at
`market_inference.py:170-176`, all markets derive from one `score_grid`.
Correct Score is a genuine probability grid; the API returns a bounded top-6 view,
documented at `market_inference.py:164-169`.

---

## 6. Model inventory and artifact provenance

| Model                           | Code                   | Artifact                | Trained on | Status                |
| ------------------------------- | ---------------------- | ----------------------- | ---------- | --------------------- |
| Frequency baseline              | `eval_pipeline.py`     | n/a (computed)          | same split | VERIFIED              |
| Elo                             | `elo.py`               | n/a (replayed)          | same split | VERIFIED              |
| Logistic + HistGradientBoosting | `train_markets.py:240` | `model_1x2.joblib` etc. | 33,368     | VERIFIED              |
| Poisson goals                   | `goal_models.py`       | `poisson_1x2.joblib`    | 33,368     | VERIFIED              |
| Dixon-Coles                     | `goal_models.py`       | `dixon_coles_*.joblib`  | 33,368     | VERIFIED (`rho=0.04`) |

All artifacts: `trained_on 2016-08-13 .. 2025-02-26`, `feature_version v2`,
`trained_at 2026-11-01T12:03:32Z`, same random seed set. Repo and runtime copies match.

**Dixon-Coles finding (P1):** it is a real implementation with a fitted `rho`, but
`rho = 0.04` and its validation metrics are **identical to plain Poisson to four
decimals** across every market. The dependence correction contributes nothing on this
data. It is a correct implementation that does not justify its own existence yet.

---

## 7. Evaluation methodology and holdout status

**Protocol (documented in `protocol_freeze.json`):**

| Element                   | Finding                                     | Status           |
| ------------------------- | ------------------------------------------- | ---------------- |
| Chronological split       | 20% validation, then test window            | VERIFIED         |
| Train cut                 | 2025-02-26                                  | VERIFIED         |
| Validation-only selection | `chosen_by_validation` field present        | VERIFIED         |
| Fixed class ordering      | `CLASSES_1X2`, `CLASSES_OU`, `CLASSES_BTTS` | VERIFIED         |
| Test partition            | **already scored before harness revision**  | **CONTAMINATED** |
| Fresh untouched holdout   | **none**                                    | NOT AVAILABLE    |

The project states the contamination explicitly (`protocol_freeze.json:88-89`):

> `"holdout_status": "exploratory"` …
> _"the test partition was already scored by an earlier version of this harness before
> Elo, the candidate set and the metric reporting were revised. It is therefore NOT an
> untouched final holdout: every number here is exploratory."_

**This is correct and honest practice.** It must not be relabelled as a clean holdout.
A defensible estimate requires a fresh period that has never been scored.

---

## 8. Available metrics (exploratory — see §7)

Sample sizes: train 33,368 · test 5,920 (chronological, 2025-02-26 onward).

### 1X2 (multiclass) — validation split, n=5,006 (the only uncontaminated comparison)

| Candidate | Accuracy | Log loss | Brier |
|---|---:|---:|---:|
| training_frequency | 0.4383 | 1.0740 | 0.6497 |
| **logistic_regression** (published) | **0.5180** | **0.9828** | **0.5863** |
| poisson_goals | 0.4429 | 1.0625 | 0.6410 |
| dixon_coles | 0.4429 | 1.0625 | 0.6410 |

**Logistic regression wins on validation and is what is published**
(`algorithm: multinomial_logistic_regression`). Poisson and Dixon-Coles are clearly
worse (1.0625 vs 0.9828) and are not served.

### Test block (n=5,889) — exploratory, contaminated

| Model | Accuracy | Log loss | Brier |
|---|---:|---:|---:|
| logistic_regression | 0.5079 | 0.9990 | 0.5964 |
| frequency baseline | 0.4298 | 1.0753 | 0.6510 |

Class distribution: H 0.430, D 0.253, A 0.317. Log loss 0.999 vs 1.075 is a modest,
genuine improvement over the baseline.

---

## 9. Probability quality and betting readiness

| Check                     | Result                                   | Status          |
| ------------------------- | ---------------------------------------- | --------------- |
| Finite, within [0,1]      | yes                                      | VERIFIED        |
| 1X2 normalised to 1       | yes (0.576/0.173/0.251)                  | VERIFIED        |
| O/U, BTTS normalised      | yes                                      | VERIFIED        |
| Double Chance = H+D etc.  | exact                                    | VERIFIED        |
| Calibration measured      | reliability curves exist                 | VERIFIED        |
| Calibration **applied**   | **no calibrator is fitted or persisted** | NOT IMPLEMENTED |
| Odds ingestion            | **no odds table, no ingestion**          | NOT IMPLEMENTED |
| Margin removal / EV / CLV | **absent**                               | NOT IMPLEMENTED |

**Normalisation is not calibration.** The outputs are coherent and the published model is
the better candidate on validation, but nothing measures whether the stated
probabilities match observed frequencies out of sample — and no calibrator is applied.

**No betting readiness claim is possible.** Without odds there is no way to compute edge.

---

## 10. Training / inference / API integration

| Link                          | Finding                                       | Status                                                                           |
| ----------------------------- | --------------------------------------------- | -------------------------------------------------------------------------------- |
| DB → dataset                  | Rails API, per-season, no truncation observed | VERIFIED                                                                         |
| Dataset → features            | same `enrich_history` for train and serve     | VERIFIED                                                                         |
| Feature schema parity         | `feature_version v2`, 53 features both sides  | VERIFIED                                                                         |
| Artifact metadata validated   | `meta.json` checked on load                   | VERIFIED                                                                         |
| Missing artifact              | returns **503**, no silent fallback           | VERIFIED                                                                         |
| Derived-market mapping        | `DERIVED_MARKET_SOURCE` explicit              | VERIFIED                                                                         |
| Output validation             | probabilities checked before return           | VERIFIED                                                                         |
| Retraining separate from sync | no retrain in sync jobs                       | VERIFIED                                                                         |
| Promotion gate                | publication via `published_models.json`       | PARTIALLY VERIFIED — gate is a file write, not an automated evaluation threshold |
| Rollback                      | previous artifacts retained on disk           | PARTIALLY VERIFIED — no explicit version-pinning mechanism documented            |

---

## 11. Test results

```
docker compose exec -T ml python -m pytest -q
283 passed
```

Tests run against **synthetic fixtures**, which proves code behaviour, not model quality.
Leakage tests are genuine (truncation, future-result, simultaneous-kickoff, split
integrity) and were verified by reading both the test and the implementation.

---

## 12. Findings by priority

### P0 — blocking a credible quality claim

| #    | Finding                                                                                        | Evidence                                                                |
| ---- | ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| P0-1 | **No untouched holdout.** Test partition already scored; every reported metric is exploratory. | `protocol_freeze.json:88-89`                                            |
| P0-2 | **No odds data.** No table, no ingestion, no EV. Betting readiness cannot be assessed.         | `\dt` shows no odds tables; `grep odds ml/app` returns only disclaimers |

### P1 — material quality problems

| #    | Finding                                                                                         | Evidence                                    |
| ---- | ----------------------------------------------------------------------------------------------- | ------------------------------------------- |
| P1-1 | **No calibration applied.** Measured but no isotonic/Platt calibrator persisted.                | `grep calibrat app/*.py`                    |
| P1-2 | **Dixon-Coles adds nothing** (rho=0.04, metrics identical to Poisson).                          | `model_comparison.json`                     |
| P1-3 | **Metrics file and protocol freeze disagree** on split ratios (70/15/15 vs 20/20) and seed set. | `model_comparison.json` vs artifact `split` |
| P1-4 | Model edge is small (1X2 log loss 0.999 vs baseline 1.075, accuracy ~51%). The goal model is materially worse (1.0625 vs 0.9828 on validation) and is not published. | `model_comparison.json` |

### P2 — design gaps

| #    | Finding                                                                       |
| ---- | ----------------------------------------------------------------------------- |
| P2-1 | Elo never resets across seasons; promotion/relegation not modelled explicitly |
| P2-2 | No per-competition calibration or per-competition metrics reported            |
| P2-3 | Promotion gate is a JSON write with no automated threshold check              |
| P2-4 | Evaluation is global, not reported per competition/season                     |

### P3 — hygiene

| #    | Finding                                                         |
| ---- | --------------------------------------------------------------- |
| P3-1 | 95 untracked files including ML modules; no commit boundary     |
| P3-2 | Repo `ml/artifacts/` duplicated by a runtime volume; drift risk |

---

## 13. Contradictions with previous reports — resolved

| Previous claim                                                           | Actual                                | Resolution                              |
| ------------------------------------------------------------------------ | ------------------------------------- | --------------------------------------- |
| "`features_v2.py` / `goal_models.py` / `eval_pipeline.py` may not exist" | All exist                             | Stale report; current checkout verified |
| "Dixon-Coles implemented as a distinct model"                            | Implemented, rho≈0, metrics identical | True but functionally inert             |
| "Mobile `tsc` 0 errors" (an earlier report)                              | Was 15 at the time                    | Already corrected in handout §7         |
| "Test window is a valid holdout" (implied by early reports)              | Explicitly exploratory                | Corrected by `protocol_freeze.json`     |
| "132 affected fixtures" (handout §11)                                    | 371                                   | Corrected in §12                        |

---

## 14. Outstanding work and dependencies

1. **Accumulate a fresh holdout.** Requires completed matches after 2025-02-26 that have
   never been scored. Currently 5,920 exist but are spent.
2. **Odds ingestion** (any source) before any betting claim.
3. **Fit and persist a calibrator** on validation data only.
4. **Decide Dixon-Coles' fate** — evaluate rho on a larger sample or remove it.
5. **Reconcile** `model_comparison.json` with the protocol actually used.

---

## 15. Prioritized plan

| Priority | Action                                                                   | Effort | Acceptance criteria                                                         |
| -------- | ------------------------------------------------------------------------ | ------ | --------------------------------------------------------------------------- |
| **P0**   | Freeze current artifacts; do not tune further on the current test window | 0.5d   | Documented freeze; no further scoring of 2025-02-26+ until holdout declared |
| **P0**   | Build a holdout manifest: which dates are spent, which are clean         | 1d     | Machine-readable list; evaluator refuses spent dates                        |
| **P1**   | Fit isotonic calibrator on validation only; persist alongside artifact   | 1–2d   | ECE improves on validation; test untouched                                  |
| **P1**   | Odds ingestion + margin removal + EV/CLV                                 | 3–5d   | ≥1 season of closing odds; EV computed and reported                         |
| **P1**   | Reconcile evaluation config drift                                        | 0.5d   | Single source of truth for split/seeds                                      |
| **P2**   | Per-competition metrics; season-aware Elo                                | 2–3d   | Reported per competition                                                    |
| **P2**   | Automated promotion gate                                                 | 1d     | Promotion requires threshold pass                                           |

---

---

## 16. Audit side effect (disclosed)

The end-to-end verification issued `POST /api/v1/predictions {match_id:4357}`, which
**stores** predictions. This created prediction ids **83–87** (one per market) at
`2026-11-03 12:12:37Z`. The prediction count therefore moved 62 → 67.

No existing prediction was modified. Ids 1–82 are unchanged. This is a consequence of
exercising the real serving path rather than a mock, and is recorded here so the count
change is not mistaken for an unexplained write.

## Appendix — evidence index

| Claim                       | File:line / command                                                |
| --------------------------- | ------------------------------------------------------------------ |
| State update after features | `ml/app/features_v2.py:332-419`                                    |
| Strictly-before filter      | `ml/app/features.py:191`                                           |
| History merge dedupe        | `ml/app/features_v2.py:444-480`                                    |
| Labels only when completed  | `ml/app/features_v2.py:388-395`                                    |
| Markets from one grid       | `ml/app/market_inference.py:160-176`                               |
| Top-6 truncation            | `ml/app/market_inference.py:164-169`                               |
| Dixon-Coles rho             | `ml/artifacts/*.meta.json` (`rho=0.04`)                            |
| Holdout contamination       | `ml/artifacts/evaluation/protocol_freeze.json:88-89`               |
| Training cut                | `ml/artifacts/model_1x2.joblib.meta.json` (`train_end 2025-02-26`) |
| Partition arithmetic        | `psql` completed counts (33,368 / 5,920 / 39,288)                  |
| No odds                     | `psql \dt`, `grep -rn odds ml/app`                                 |
| Tests                       | `docker compose exec -T ml python -m pytest -q` → 283 passed       |
| Live markets                | `POST /api/v1/predictions {match_id:4357}`                         |
