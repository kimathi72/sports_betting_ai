# Prospective evaluation — design (Phase C)

**Status: DESIGN ONLY. No implementation, no automation, no writes.**

## 1. Why prospective evaluation is the only clean evidence left

Every completed match is spent (see `ml/evaluation/spent_manifest.json`). The test
window was scored before the harness was revised, so it cannot serve as holdout. The
only uncontaminated evidence available to this project from now on is **predictions
made before a match kicks off, scored against the result that follows**.

That is what prospective evaluation is, and why it cannot be backfilled: a prediction
whose timestamp is reconstructed after the result is not evidence.

## 2. The four categories, kept strictly separate

| Category                  | Source data                     | May inform model development? | May be called "holdout"? |
| ------------------------- | ------------------------------- | ----------------------------- | ------------------------ |
| Retrospective development | pre-2025-02-26 rows             | yes                           | no                       |
| Calibration assessment    | disjoint post-cut rows          | no                            | no                       |
| Prospective monitoring    | live predictions, pre-kickoff   | no                            | no                       |
| Final untouched holdout   | rows after freeze, never scored | no                            | **yes, once**            |

Conflating these is the failure mode this whole workstream exists to prevent.

## 3. Data model

Two new concepts, both append-only:

### 3.1 Prediction record (exists today)

`predictions` already stores `match_id`, `market`, probabilities and `created_at`.
Prospective evaluation needs `created_at` to be the **real** issue time and needs the
model provenance attached.

Required additions (not implemented):

| Column                | Purpose                                                                         |
| --------------------- | ------------------------------------------------------------------------------- |
| `model_freeze_digest` | which frozen generation issued it (ties to `evaluation/model_freeze_v2.1.json`) |
| `feature_version`     | e.g. `v2`                                                                       |
| `issued_at`           | explicit issue timestamp, distinct from row-creation time                       |
| `is_prospective`      | true only if `issued_at < kickoff_at`                                           |

`issued_at` must be written by the serving path at issue time. It must never be
backfilled.

### 3.2 Prospective evaluation record (new table)

| Column                                       | Purpose                              |
| -------------------------------------------- | ------------------------------------ |
| `prediction_id`                              | FK, unique — prevents double scoring |
| `match_id`                                   | for reporting                        |
| `evaluated_at`                               | when scoring happened                |
| `actual_home_score`, `actual_away_score`     | copied at scoring time               |
| `market`, `log_loss`, `brier`, `was_correct` | per-market outcome                   |
| `protocol_digest`                            | which protocol governed the run      |
| timing_eligible`                             | false when `issued_at >= kickoff_at` |

## 4. Eligibility rules

A prediction qualifies for prospective evaluation only if ALL hold:

1. `issued_at < kickoff_at` — issued before the match began.
2. The match status is `completed` with both scores present.
3. The match was not postponed, cancelled or abandoned after the prediction (a
   rescheduled match invalidates the prediction against its original kickoff).
4. The prediction has not already been evaluated (`prediction_id` unique).
5. The model freeze digest is known and matches a recorded freeze.

**Explicitly rejected:** predictions created after kickoff, predictions whose match
was rescheduled, and predictions without provenance.

## 5. Workflow

```
match scheduled
   ↓  serving path issues prediction, writes issued_at + freeze digest
kickoff_at passes
   ↓  result synchronised (existing pipeline)
scoring job (manual first, automated later)
   ↓  eligibility checks → append ProspectiveEvaluation
reporting
   ↓  calibration by competition, over time, with sample sizes
```

## 6. Postponed / abandoned / rescheduled handling

| Event                        | Effect on prediction                                                            |
| ---------------------------- | ------------------------------------------------------------------------------- |
| Postponed before kickoff     | evaluate against the NEW kickoff only if re-issued; original is void            |
| Abandoned mid-match          | excluded; no result to score                                                    |
| Rescheduled after prediction | original prediction void; record as `invalidated`, never scored                 |
| Score corrected by provider  | re-scoring forbidden; first final result stands, correction recorded separately |

## 7. What this design deliberately does NOT do

- No automated retraining triggered by new results.
- No model promotion from prospective metrics.
- No backfilled or reconstructed predictions.
- No scoring of the current spent window as if it were prospective.

## 8. Minimum sample before any claim

Prospective evidence is noisy. A defensible claim needs, per market:

| Requirement           | Threshold                                  |
| --------------------- | ------------------------------------------ |
| Predictions evaluated | ≥ 1,000                                    |
| Distinct competitions | ≥ 3                                        |
| Time span             | ≥ 3 months                                 |
| Per-competition n     | ≥ 200 before any per-competition statement |

Below these, the correct output is **"insufficient evidence"**.

## 9. Implementation steps (each requires approval)

1. Add `issued_at`, `model_freeze_digest`, `feature_version` columns (migration).
2. Write them from the serving path; add a test that a post-kickoff issue is refused.
3. Add `prospective_evaluations` table with the unique prediction constraint.
4. Build the scoring job as a **manual** rake task first.
5. Only after review, schedule it.

---

## 10. Status — implemented and exercised (2026-11-04)

Steps 1–4 of §9 are done and verified against the running stack. Step 5 (scheduling)
is deliberately **not** done.

| Step | State | Evidence |
| --- | --- | --- |
| 1. Columns + table | applied to development | `predictions.model_freeze_digest`, `predictions.issued_kickoff_at`, `prospective_evaluation_records` |
| 2. Written by the serving path | live | every prediction issued by the deployed C2 stack carries all three; verified by SQL, not by reading code |
| 3. Unique prediction constraint | live | unique index on `prediction_id`; a second scoring raises `AlreadyEvaluated` |
| 4. Manual scoring task | `rake predictions:sweep` | preview by default, `APPLY=1` writes |
| 5. Scheduling | **not done** | requires an explicit decision (§9 of the handout explains why jobs are not started by accident) |

### 10.1 The four evaluation categories, as they now stand

| Category | Where the data comes from | Current state |
| --- | --- | --- |
| Historical development evaluation | train partition, `ml/evaluation/eval_protocol_v2.json` | exists; exploratory only |
| Calibration development | validation partition (fit) + disjoint assessment partition | infrastructure only; **nothing fitted** |
| Prospective evaluation | predictions issued before kickoff, scored after the result | **pipeline live, evidence still insufficient** |
| Untouched final holdout | matches completing after the freeze | empty by construction; fills only with time |

The historical test partition is **not** a holdout and is not treated as one:
`require_clean_holdout` rejects a date that the spent manifest marks as scored.

### 10.2 What the prospective pipeline now guarantees

- A prediction is refused **at issue time** if the fixture has already kicked off,
  even when its stored status still says `scheduled` (the stale-status hole found
  on 2026-11-04 — results not yet ingested).
- A prediction issued after kickoff can never be scored: the eligibility gate
  rejects `issued_at_or_after_kickoff`, and the sweep reports it rather than
  retrying it.
- A prediction with no freeze digest is not evidence. The sweep reports
  `missing_freeze_digest`; the digest itself is only ever emitted by the ML service
  when the artifact checksum matches the freeze record.
- The issued probabilities are never rewritten. The outcome goes to a separate row.
- Duplicate scoring is prevented in Ruby and in the database.

### 10.3 Honest current position

As of 2026-11-04, **zero** predictions qualify as prospective evidence:

- The 134 pre-existing predictions have no feature version or digest (correctly NULL).
- Ten predictions were issued for two fixtures whose kickoff had already passed
  (results not yet ingested). They are stored, and the gate refuses them — they are
  **not** evidence and must never be counted as such.
- Every prediction issued from now on qualifies only after its fixture completes.

The first genuinely scorable evidence therefore requires: a prediction issued before
kickoff → the match played → the result ingested → `rake predictions:sweep APPLY=1`.

**INSUFFICIENT EVIDENCE — NO BETTING RECOMMENDATION.**

### 10.4 Daily operating procedure (manual, by design)

```bash
# 1. see what is waiting to be scored (writes nothing)
docker compose exec -T web bundle exec rake predictions:sweep

# 2. ingest results for fixtures that have finished
docker compose exec -T web bin/rails runner \
  tmp/ingest_recent_results.rb eng.1 2026/27 <FROM> <TO> [apply]

# 3. write the evaluation records
docker compose exec -T web bundle exec rake predictions:sweep APPLY=1
```

Step 2 previews by default and only completes rows that are still `scheduled` and
whose provider status is full time; it never creates a fixture and never overwrites a
result.

---

## 11. Validation safeguards — the four categories, enforced (2026-11-04)

The four categories must never be confused, because each answers a different
question and only one of them can support a betting claim.

| Category | Data | What it may be used for | What it may NOT be used for |
| --- | --- | --- | --- |
| **Development evaluation** | train partition (28,364 rows) | fitting, feature selection | any performance claim |
| **Calibration development** | validation partition (5,006 rows), split into disjoint fit/assessment | choosing and fitting a calibrator | final performance claims |
| **Prospective validation** | predictions issued before kickoff, scored after the result | the only honest performance evidence | — |
| **Untouched final holdout** | matches completing after the freeze | one final, single-use check | anything before the end of the study |

### 11.1 The rules, and where each is enforced

| Rule | Enforced by |
| --- | --- |
| The historical test window is exploratory, never a holdout | `ml/app/eval_protocol.py` `require_clean_holdout` + `spent_manifest.json` |
| A calibrator is never fitted on the data it is assessed on | `ml/app/calibration.py` `CalibrationStudy` refuses overlap before fitting |
| A prediction issued at or after kickoff is not evidence | `Predictions::ProspectiveEligibility` (`issued_at_or_after_kickoff`) |
| A prediction for a rescheduled fixture is not evidence | `Predictions::ProspectiveEligibility` (`kickoff_changed_since_issue`) |
| A prediction without a verified freeze digest is not evidence | `Predictions::ProspectiveEligibility` (`missing_freeze_digest`) |
| A prediction is scored at most once | unique index on `prospective_evaluation_records.prediction_id` |
| Issued probabilities are never rewritten | `Prediction#evidence_must_not_be_rewritten` |
| A result is never overwritten by a different provider score | `Import::ApiFootballReconciler#reconcile` → `:conflict` |
| A result run never creates a fixture | `Sync::EspnResultSynchronizer` (skips unknown fixtures) |
| A result run never touches another season's fixture | `Sync::EspnResultSynchronizer#decide` (season association check) |

### 11.2 What "insufficient evidence" means operationally

The system must say **INSUFFICIENT EVIDENCE — NO BETTING RECOMMENDATION** whenever
any of the following is true, and today all of them are:

1. prospective evaluation records = 0;
2. no calibrator has been fitted on a disjoint assessment partition;
3. no odds data exists in the database;
4. no untouched holdout exists.

A high model probability is not an edge. It is a number from a model whose
calibration has not been measured against outcomes it has never seen.

### 11.3 The daily loop that produces evidence (manual, by design)

```bash
# 1. what would be scored right now (writes nothing)
docker compose exec -T web bundle exec rake predictions:sweep

# 2. collect results for the days that have finished (PREVIEW by default)
docker compose exec -T web bundle exec rake 'results:sync[2026-11-03,2026-11-04]'

# 3. apply, once the preview has been read
APPLY=1 docker compose exec -T web bundle exec rake 'results:sync[2026-11-03,2026-11-04]'

# 4. score the predictions whose fixtures are now complete
APPLY=1 docker compose exec -T web bundle exec rake predictions:sweep
```

Step 2 is the new Phase D1 entry point. It is **not scheduled**: enabling it on a
timer is a policy decision, and this project starts background writes only on
explicit instruction.
