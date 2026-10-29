"""Benchmark candidate models for every market on one chronological split.

Run inside the ML image (never against WSL's global Python):

    docker compose run --rm --entrypoint python ml -m ml.app.evaluate_markets

    # one market, JSON to stdout
    docker compose run --rm --entrypoint python ml -m ml.app.evaluate_markets --market 1x2

Environment:
    RAILS_BASE_URL   default http://web:3000
    EVAL_OUTPUT_DIR  default /app/artifacts/evaluation (host: ml/artifacts/evaluation)

WHAT THIS DOES NOT DO
---------------------
It never writes or replaces a production artifact. It writes a metrics report
only, so a candidate can be judged before anything is promoted. Selection uses
VALIDATION metrics; the final TEST partition is reported for the record and is
never used to choose a model.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

from ml.app.elo import (
    DEFAULT_DRAW_RATE,
    DEFAULT_HOME_ADVANTAGE,
    DEFAULT_K,
    INITIAL_RATING,
    EloRatings,
    probabilities_from_ratings,
)
from ml.app.evaluation import (
    Baseline,
    EvaluationError,
    build_rows,
    chronological_split,
    compare_models,
    report_to_json,
)
from ml.app.model_store import FEATURE_NAMES
from ml.app.training import fetch_all_completed_matches

# Binary markets use their own class order, matching what the API returns.
MARKET_CLASSES = {
    "1x2": ["H", "D", "A"],
    "over_under_2.5": ["Over", "Under"],
    "btts": ["Yes", "No"],
}


def _env_info() -> dict:
    import sklearn
    import scipy

    return {
        "python": platform.python_version(),
        "numpy": np.__version__,
        "scipy": scipy.__version__,
        "scikit_learn": sklearn.__version__,
        "feature_count": len(FEATURE_NAMES),
    }


# ---------------------------------------------------------------------------
# Candidate models. Each factory receives TRAIN rows only.
# ---------------------------------------------------------------------------

def make_baseline(name: str, classes: list[str]):
    def factory(train):
        baseline = (
            Baseline.majority(train) if name == "majority" else Baseline.frequency(train)
        )
        return lambda rows: baseline.predict_proba(rows, classes=classes)

    return factory


def make_logistic(classes: list[str]):
    """Regularized multinomial logistic regression.

    StandardScaler lives inside the Pipeline, so scaling is fitted on train rows
    only — the classic leak when a scaler sees the whole dataset.
    """
    def factory(train):
        from sklearn.linear_model import LogisticRegression
        from sklearn.pipeline import Pipeline
        from sklearn.preprocessing import StandardScaler

        X = np.array([r.features for r in train], dtype=float)
        y = np.array([r.y for r in train], dtype=object)

        model = Pipeline(
            [
                ("scale", StandardScaler()),
                ("clf", LogisticRegression(max_iter=2000, C=1.0)),
            ]
        )
        model.fit(X, y)

        def predict(rows):
            proba = model.predict_proba(np.array([r.features for r in rows], dtype=float))
            return _align(model.classes_, proba, classes)

        return predict

    return factory


def make_gradient_boosting(classes: list[str]):
    """The currently deployed model family, for a like-for-like comparison."""
    def factory(train):
        from sklearn.ensemble import HistGradientBoostingClassifier

        X = np.array([r.features for r in train], dtype=float)
        y = np.array([r.y for r in train], dtype=object)

        model = HistGradientBoostingClassifier(random_state=42, max_iter=200)
        model.fit(X, y)

        def predict(rows):
            proba = model.predict_proba(np.array([r.features for r in rows], dtype=float))
            return _align(model.classes_, proba, classes)

        return predict

    return factory


def make_poisson(classes: list[str]):
    """Independent Poisson goal model with a home-advantage term.

    Goals are modelled as two Poisson counts fitted on TRAIN rows. From the goal
    matrix we derive 1X2, Over/Under 2.5 and BTTS from the SAME distribution, so
    the three markets are internally consistent by construction.

    Team strength is estimated from train rows only; the prediction for a fixture
    uses the strengths in effect at fit time.
    """
    def factory(train):
        from scipy.stats import poisson

        # League-average goals from train rows.
        goals = np.array([[r0.features[1], r0.features[2]] for r0 in train], dtype=float)
        home_avg = max(goals[:, 0].mean(), 0.1)
        away_avg = max(goals[:, 1].mean(), 0.1)

        # A simple home-advantage ratio, also from train.
        home_adv = home_avg / max(away_avg, 1e-6)

        def predict(rows):
            out = []
            for row in rows:
                # Use the row's own observed form as a weak strength proxy,
                # scaled to a plausible mean goals value.
                home_form = row.features[1] / 5.0 if len(row.features) > 1 else 1.0
                away_form = row.features[8] / 5.0 if len(row.features) > 8 else 1.0
                lam_home = max(home_form * home_adv, 0.05)
                lam_away = max(away_form, 0.05)

                grid = np.outer(
                    poisson.pmf(np.arange(0, 8), lam_home),
                    poisson.pmf(np.arange(0, 8), lam_away),
                )
                p_home = float(np.tril(grid, -1).sum())
                p_draw = float(np.trace(grid))
                p_away = float(np.triu(grid, 1).sum())
                total = p_home + p_draw + p_away

                if classes == ["H", "D", "A"]:
                    out.append([p_home / total, p_draw / total, p_away / total])
                elif classes == ["Over", "Under"]:
                    over = sum(
                        grid[i, j]
                        for i in range(grid.shape[0])
                        for j in range(grid.shape[1])
                        if i + j > 2.5
                    )
                    out.append([float(over), float(1.0 - over)])
                else:  # Yes/No
                    btts_yes = float(grid[1:, 1:].sum() / grid.sum())
                    out.append([btts_yes, 1.0 - btts_yes])

            return np.array(out)

        return predict

    return factory


def make_elo(classes: list[str]):
    """Fixed-parameter Elo reference model (see ``ml.app.elo``).

    This is a *benchmark*, not a production candidate: no parameter is fitted or
    tuned, so it cannot have been selected on validation data. It answers one
    question — does a 17-feature model actually beat a rating table with three
    hand-set constants?

    Timing: ratings are replayed over TRAIN rows only, chronologically, with
    same-kickoff matches grouped into a round. Each scored row is predicted from
    the rating table as it stood at that match's kickoff, so a match's own
    result never contributes to its own probability.

    Over/Under and BTTS have no Elo interpretation. Rather than invent one, the
    fallback is the TRAIN class frequency of the market, and the report labels
    those numbers a frequency proxy so nobody mistakes them for an Elo edge.
    """

    def factory(train):
        train_matches = [
            {
                "id": row.match_id,
                "kickoff_at": row.kickoff_at,
                "home_team_id": row.home_team_id,
                "away_team_id": row.away_team_id,
                "home_score": row.home_score,
                "away_score": row.away_score,
            }
            for row in train
        ]

        # One chronological pass over train. predict_chronologically emits the
        # pre-match ratings for every round, so we keep the table it built for
        # each scored row directly instead of replaying prefixes per row.
        ratings = EloRatings()
        pre_match = {
            p["match_id"]: (p["home_rating"], p["away_rating"])
            for p in ratings.predict_chronologically(train_matches)
        }

        frequency = Baseline.frequency(train)

        def predict(rows):
            out = []
            for row in rows:
                if classes == ["H", "D", "A"]:
                    if row.match_id in pre_match:
                        home_rating, away_rating = pre_match[row.match_id]
                    else:
                        # Not a train row: take the rating table as it stood just
                        # before this kickoff. Places the row at the end of its
                        # own timestamp group, so a simultaneous result still
                        # does not reach it.
                        prior = [
                            m for m in train_matches
                            if (str(m.get("kickoff_at") or ""), m.get("id") or 0)
                            < (row.kickoff_at, row.match_id)
                        ]
                        replay = EloRatings()
                        replay.predict_chronologically(prior)
                        home_rating = replay.rating(row.home_team_id)
                        away_rating = replay.rating(row.away_team_id)

                    probs = probabilities_from_ratings(
                        home_rating, away_rating, ratings.home_advantage, ratings.draw_rate
                    )
                    out.append([probs["H"], probs["D"], probs["A"]])
                else:
                    # Documented fallback for markets Elo cannot express. Uses
                    # train labels only, so it leaks nothing.
                    vector = np.asarray(frequency.predict_proba([row], classes=classes)[0], dtype=float)
                    # A train set containing only one class yields a one-hot row;
                    # normalising keeps the output a valid distribution.
                    total = vector.sum()
                    out.append(vector / total if total > 0 else np.full(len(classes), 1.0 / len(classes)))
            return np.array(out)

        return predict

    return factory


def _align(native, proba: np.ndarray, classes: list[str]) -> np.ndarray:
    """Reorder probability columns into the requested class order."""
    native = list(native)
    idx = [native.index(c) for c in classes]
    return np.asarray(proba)[:, idx]


CANDIDATES = {
    market: [
        ("majority", make_baseline("majority", classes)),
        ("frequency", make_baseline("frequency", classes)),
        ("logistic_regression", make_logistic(classes)),
        ("hist_gradient_boosting", make_gradient_boosting(classes)),
        ("poisson_goals", make_poisson(classes)),
        ("elo", make_elo(classes)),
    ]
    for market, classes in MARKET_CLASSES.items()
}


# ---------------------------------------------------------------------------
# Frozen evaluation protocol
# ---------------------------------------------------------------------------
#
# The current test partition has already been scored, so it can never again be a
# pristine holdout. A future, genuinely new holdout is only comparable with this
# one if it is scored with the SAME protocol. Freezing the protocol here - and
# checking its digest in tests - makes protocol drift a deliberate act rather
# than an accident.
#
# Change the protocol only by writing a new freeze file. Editing the constants
# below without doing so fails test_the_protocol_is_frozen_with_a_stable_digest.

# Evaluation reports live beside the artifacts (bind-mounted from the host in
# Compose). EVAL_FREEZE_PATH lets a test or a fresh-holdout run point elsewhere.
PROTOCOL_FREEZE_PATH = Path(
    os.environ.get(
        "EVAL_FREEZE_PATH",
        Path(__file__).resolve().parent.parent / "artifacts" / "evaluation" / "protocol_freeze.json",
    )
)

SPLIT_VALIDATION_FRACTION = 0.2
SPLIT_TEST_FRACTION = 0.2
BOOTSTRAP_RESAMPLES = 2000
BOOTSTRAP_SEED = 20240529
BASELINE_FOR_DELTAS = "frequency"


def current_protocol() -> dict:
    """Everything that must stay fixed for two evaluations to be comparable."""
    return {
        "split": {
            "order": "kickoff_at, then match_id",
            "validation_fraction": SPLIT_VALIDATION_FRACTION,
            "test_fraction": SPLIT_TEST_FRACTION,
            "simultaneous_kickoffs_kept_together": True,
        },
        "selection_rule": "lowest validation log loss",
        "baseline_for_deltas": BASELINE_FOR_DELTAS,
        "bootstrap": {
            "resamples": BOOTSTRAP_RESAMPLES,
            "seed": BOOTSTRAP_SEED,
            "paired": True,
            "confidence": 0.95,
        },
        "elo": {
            "initial_rating": INITIAL_RATING,
            "k": DEFAULT_K,
            "home_advantage": DEFAULT_HOME_ADVANTAGE,
            "draw_rate": DEFAULT_DRAW_RATE,
            "margin_of_victory": "none",
        },
        "feature_schema": list(FEATURE_NAMES),
        "candidates": {market: [name for name, _ in entries] for market, entries in CANDIDATES.items()},
        "class_orders": {market: list(classes) for market, classes in MARKET_CLASSES.items()},
    }


def protocol_digest(protocol: dict) -> str:
    """Stable SHA-256 over the canonical JSON form of a protocol."""
    import hashlib

    canonical = json.dumps(protocol, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def load_frozen_config(path: Path | None = None) -> dict:
    """Read the freeze record. Raises rather than pretending it exists."""
    target = Path(path or PROTOCOL_FREEZE_PATH)
    if not target.is_file():
        raise EvaluationError(
            f"no frozen evaluation protocol at {target}; run "
            "python -m ml.app.evaluate_markets --freeze to create one"
        )
    return json.loads(target.read_text())


def write_freeze(directory: Path, *, holdout_status: str, contamination: str,
                 frozen_by: str = "ml.app.evaluate_markets --freeze") -> Path:
    """Write the freeze record next to the evaluation reports."""
    protocol = current_protocol()
    payload = {
        "frozen_at": datetime.now(timezone.utc).isoformat(),
        "frozen_by": frozen_by,
        "protocol": protocol,
        "digest": protocol_digest(protocol),
        "holdout_status": holdout_status,
        "contamination": contamination,
    }
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / "protocol_freeze.json"
    target.write_text(json.dumps(payload, indent=2) + "\n")
    return target


def evaluate_market(market: str, matches: list[dict]) -> dict:
    classes = MARKET_CLASSES[market]
    rows = build_rows(matches, market)
    split = chronological_split(
        rows,
        validation_fraction=SPLIT_VALIDATION_FRACTION,
        test_fraction=SPLIT_TEST_FRACTION,
    )

    reports = compare_models(
        split,
        market,
        CANDIDATES[market],
        classes=classes,
        baseline=BASELINE_FOR_DELTAS,
        bootstrap_resamples=BOOTSTRAP_RESAMPLES,
    )

    for report in reports:
        if report.name == "elo":
            report.notes = (
                "fixed-parameter Elo (K=20, home advantage=60 rating points, "
                "draw rate=0.25, no margin-of-victory); ratings replayed over "
                "train rows only, same-kickoff matches grouped into a round. "
                + (
                    ""
                    if market == "1x2"
                    else "Over/Under and BTTS are NOT Elo outputs: this row uses "
                    "the train frequency as a documented placeholder. "
                )
                + "Nothing was tuned, so it cannot have been fitted to validation."
            )
        elif report.name == "poisson_goals":
            report.notes = (
                "POISSON PROXY, not a fitted Poisson regression: strengths come "
                "from the row's own last-5 form features scaled to train goals "
                "averages. Internally consistent across markets; do not read it "
                "as a calibrated goal model."
            )

    payload = report_to_json(
        reports,
        extra={
            "environment": _env_info(),
            "market": market,
            "protocol_digest": protocol_digest(current_protocol()),
        },
    )

    # Selection is by VALIDATION log loss — never by test performance.
    best = min(reports, key=lambda r: r.metrics["validation"]["log_loss"])
    payload["selected_by_validation_log_loss"] = best.name
    payload["test_metrics_of_selected"] = best.metrics["test"]

    payload.update(_test_partition_status(best, reports))

    return payload


# The candidate list, the feature set and the Eli parameters were all revised
# AFTER this test partition had already been scored once (see docs/roadmap.md,
# Milestone E2). Test figures below are therefore EXPLORATORY, and the report
# says so in the machine-readable output rather than in a comment a reader of
# the JSON never sees.
TEST_PARTITION_STATUS = "exploratory"
TEST_PARTITION_EXPLANATION = (
    "The test partition was already scored by an earlier version of this harness "
    "before Elo, the candidate set and the metric reporting were revised. It is "
    "therefore NOT an untouched final holdout: every number here is exploratory. "
    "Model selection uses validation log loss only, which this revision did not "
    "consult. A defensible final estimate requires a fresh, as-yet unscored "
    "period once more seasons are imported."
)


def _test_partition_status(best, reports) -> dict:
    ranking = sorted(reports, key=lambda r: r.metrics["validation"]["log_loss"])
    return {
        "test_partition_status": TEST_PARTITION_STATUS,
        "test_partition_explanation": TEST_PARTITION_EXPLANATION,
        "validation_ranking": [r.name for r in ranking],
        "validation_log_loss_of_selected": best.metrics["validation"]["log_loss"],
        "selection_rule": "lowest validation log loss",
    }


def _fmt(value: float) -> str:
    return f"{value:.4f}"


def print_table(payload: dict) -> None:
    print(f"\n{'=' * 100}")
    print(f"MARKET: {payload['market']}   split: {payload['split']}")
    print(f"test class distribution: {payload['class_distribution_test']}")
    print(f"{'=' * 100}")
    print(
        f"{'model':<24}{'val ll':>9}{'test ll':>9}{'test acc':>10}"
        f"{'test brier':>12}{'dLL vs freq':>13}{'95% CI':>21}"
    )
    print("-" * 100)
    for model in payload["models"]:
        val = model["metrics"]["validation"]
        test = model["metrics"]["test"]
        delta = test.get("log_loss_delta_vs_baseline")
        if delta:
            d = f"{delta['observed_delta']:+.4f}"
            ci = f"[{delta['ci_low']:+.3f}, {delta['ci_high']:+.3f}]"
        else:
            d, ci = "baseline", ""
        print(
            f"{model['name']:<24}{_fmt(val['log_loss']):>9}"
            f"{_fmt(test['log_loss']):>9}{_fmt(test['accuracy']):>10}"
            f"{_fmt(test['brier_score']):>12}{d:>13}{ci:>21}"
        )
    print("\ndLL = test log loss minus frequency-baseline log loss (negative is better).")
    print("CI = paired bootstrap over test rows; an interval containing 0 cannot separate the models.")
    print(f"\nvalidation ranking (selection rule): {payload['validation_ranking']}")
    print(f"selected by validation log loss: {payload['selected_by_validation_log_loss']}")
    print(f"protocol digest: {payload.get('protocol_digest')}")
    if payload.get("test_partition_status") == TEST_PARTITION_STATUS:
        print("\nWARNING: test figures are EXPLORATORY - this partition was already")
        print("scored before the harness was revised. Not an untouched final holdout.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Chronological market evaluation")
    parser.add_argument("--market", action="append", choices=sorted(MARKET_CLASSES),
                        help="market to evaluate (repeatable); default: all")
    parser.add_argument("--base-url", default=os.environ.get("RAILS_BASE_URL", "http://web:3000"))
    parser.add_argument("--output-dir",
                        default=os.environ.get("EVAL_OUTPUT_DIR", "/app/artifacts/evaluation"))
    parser.add_argument(
        "--freeze",
        action="store_true",
        help="write the protocol freeze record for the CURRENT holdout and exit; "
             "run this before scoring any genuinely new holdout",
    )
    args = parser.parse_args(argv)

    if args.freeze:
        target = write_freeze(
            Path(args.output_dir),
            holdout_status=TEST_PARTITION_STATUS,
            contamination=TEST_PARTITION_EXPLANATION,
        )
        print(f"froze evaluation protocol at {target}")
        print(f"digest: {protocol_digest(current_protocol())}")
        return 0

    markets = args.market or ["1x2", "over_under_2.5", "btts"]

    try:
        matches = fetch_all_completed_matches(args.base_url)
    except Exception as exc:  # noqa: BLE001 - surface a clear, non-fatal message
        print(f"could not fetch training data from {args.base_url}: {exc}", file=sys.stderr)
        return 1

    print(f"fetched {len(matches)} completed matches from {args.base_url}")

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    for market in markets:
        try:
            payload = evaluate_market(market, matches)
        except EvaluationError as exc:
            print(f"{market}: evaluation failed: {exc}", file=sys.stderr)
            continue

        print_table(payload)

        target = out_dir / f"evaluation_{market}.json"
        target.write_text(json.dumps(payload, indent=2) + "\n")
        print(f"wrote {target}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
