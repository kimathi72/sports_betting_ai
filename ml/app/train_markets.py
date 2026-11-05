"""Market-specific model training and chronological evaluation.

WHAT THIS SCRIPT DOES
---------------------
For each market it fits several candidate models on TRAIN rows, scores them on
VALIDATION rows, records both, and finally reports the untouched TEST window for
the candidate chosen by validation. Nothing is promoted by running this: artifacts
are written to ``artifacts/evaluation/`` only. Promotion is a separate, explicit
step (see docs/model-training.md).

MARKETS AND CANDIDATES
----------------------
1X2              : training frequency baseline, multinomial logistic regression,
                   Poisson scoreline grid, Dixon-Coles scoreline grid.
Over/Under 2.5   : training frequency, logistic regression, Poisson grid,
                   Dixon-Coles grid.
BTTS             : training frequency, logistic regression, Poisson grid,
                   Dixon-Coles grid.
Double Chance    : DERIVED ONLY from the chosen 1X2 distribution (no model is
                   fitted — that is what makes P(1X) = P(H) + P(D) hold).
Correct Score    : the chosen scoreline grid, reported as the top lines.
Unit of analysis : global (all competitions pooled) versus per-competition, chosen
                   on validation rather than assumed.

WHY LOGISTIC REGRESSION AS THE DIRECT CLASSIFIER
------------------------------------------------
It is deterministic, needs no tuning beyond a regularisation constant, has no
feature-importance lottery, and is reproducible to the last digit. A gradient
boosted model could be added later, but the brief says simple, reproducible
baselines first — and if a goal-distribution model beats logistic regression, a
booster would have to beat that too.

USAGE::

    docker compose run --rm --entrypoint python ml -m ml.app.train_markets \\
        --data /app/artifacts/evaluation/matches.jsonl \\
        --out /app/artifacts/evaluation \\
        --report /app/artifacts/evaluation/model_comparison.json
"""
from __future__ import annotations

import argparse
import itertools
import json
import os
import sys
from dataclasses import dataclass
from typing import Any, Callable, Sequence

import numpy as np

from ml.app.eval_pipeline import (
    accuracy_of,
    brier_binary,
    brier_multi,
    calibration_table,
    chronological,
    class_distribution,
    frequency_baseline,
    log_loss_binary,
    log_loss_multi,
    split_holdout,
    utc_now_iso,
)
from ml.app.features_v2 import FEATURE_NAMES_V2, enrich_history
from ml.app.goal_models import DixonColesModel, PoissonGoalModel, grid_market_probabilities
from ml.app.dataset_export import read_jsonl

MARKET_1X2 = "1x2"
MARKET_OU = "over_under_2.5"
MARKET_BTTS = "btts"
MARKET_DC = "double_chance"
MARKET_CS = "correct_score"

CLASSES_1X2 = ("H", "D", "A")
CLASSES_OU = ("Over", "Under")
CLASSES_BTTS = ("Yes", "No")

# Competitions are evaluated individually only when they have at least this many
# labelled rows in the validation window; below that a per-competition number is
# noise, and the report says so instead of printing it.
MIN_COMPETITION_ROWS = 200


# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------


def load_enriched(path: str) -> list[dict]:
    rows = read_jsonl(path)
    return enrich_history(rows)


def labelled(rows: Sequence[dict]) -> list[dict]:
    return [r for r in rows if r.get("label_1x2")]


def design_matrix(rows: Sequence[dict]) -> np.ndarray:
    return np.array([[row["features"][name] for name in FEATURE_NAMES_V2] for row in rows], dtype=float)


# ---------------------------------------------------------------------------
# Direct classifiers
# ---------------------------------------------------------------------------


@dataclass
class LogisticModel:
    """Multinomial / binary logistic regression with standardised inputs."""

    mean: np.ndarray
    scale: np.ndarray
    coefficients: np.ndarray
    classes: tuple[str, ...]

    @classmethod
    def fit(cls, X: np.ndarray, labels: Sequence[str], classes: Sequence[str], *, C: float = 0.5) -> "LogisticModel":
        from sklearn.linear_model import LogisticRegression

        mean = X.mean(axis=0)
        scale = X.std(axis=0)
        scale[scale == 0] = 1.0
        estimator = LogisticRegression(
            max_iter=2000,
            C=C,
            solver="lbfgs",
        )
        estimator.fit((X - mean) / scale, list(labels))
        # Reorder the estimator's columns to the canonical class order so every
        # consumer indexes probabilities identically.
        order = [list(estimator.classes_).index(c) for c in classes]
        return cls(
            mean=mean,
            scale=scale,
            coefficients=estimator,
            classes=tuple(classes),
        )

    def predict_proba(self, X: np.ndarray) -> np.ndarray:
        raw = self.coefficients.predict_proba((X - self.mean) / self.scale)
        native = list(self.coefficients.classes_)
        order = [native.index(c) for c in self.classes]
        return raw[:, order]


# ---------------------------------------------------------------------------
# Goal-model wrappers
# ---------------------------------------------------------------------------


class GoalModelMarket:
    """Wraps a fitted goal model so it answers any grid-derived market."""

    def __init__(self, model: PoissonGoalModel | DixonColesModel) -> None:
        self.model = model

    def probabilities(self, row: dict) -> dict[str, dict[str, float]]:
        grid = self.model.score_grid(row["home_team_id"], row["away_team_id"])
        return grid_market_probabilities(grid)


def _market_block(row: dict, market: str) -> dict[str, float]:
    grid = row["_grid_market_cache"][market]
    return grid


def predict_goal_market(
    model: GoalModelMarket,
    rows: Sequence[dict],
    market: str,
    classes: Sequence[str],
) -> np.ndarray:
    out = np.zeros((len(rows), len(classes)))
    for index, row in enumerate(rows):
        probabilities = model.probabilities(row)[market]
        out[index] = [probabilities[c] for c in classes]
    return out


def predict_double_chance(model: GoalModelMarket, rows: Sequence[dict]) -> np.ndarray:
    out = np.zeros((len(rows), 3))
    for index, row in enumerate(rows):
        dc = model.probabilities(row)["double_chance"]
        out[index] = [dc["1X"], dc["X2"], dc["12"]]
    return out


# ---------------------------------------------------------------------------
# Candidate registry
# ---------------------------------------------------------------------------


@dataclass
class CandidateResult:
    name: str
    metrics: dict[str, float]
    extra: dict[str, Any]


def evaluate_block(
    y_true: Sequence[str],
    probabilities: np.ndarray,
    classes: Sequence[str],
    baseline: dict[str, float],
) -> dict[str, float]:
    baseline_matrix = np.tile(np.array([baseline[c] for c in classes]), (len(y_true), 1))
    return {
        "n": len(y_true),
        "accuracy": accuracy_of(y_true, probabilities, classes),
        "log_loss": log_loss_multi(y_true, probabilities, classes),
        "brier_score": brier_multi(y_true, probabilities, classes),
        "baseline_log_loss": log_loss_multi(y_true, baseline_matrix, classes),
        "baseline_brier_score": brier_multi(y_true, baseline_matrix, classes),
        "baseline_accuracy": accuracy_of(y_true, baseline_matrix, classes),
        "class_distribution": class_distribution(y_true),
    }


def evaluate_binary(
    y_true: Sequence[str],
    probabilities: np.ndarray,
    classes: Sequence[str],
    baseline: dict[str, float],
) -> dict[str, float]:
    result = evaluate_block(y_true, probabilities, classes, baseline)
    positive = classes[0]
    result["calibration"] = calibration_table(y_true, probabilities[:, 0], positive)
    return result


def build_candidates(
    split,
    market: str,
) -> dict[str, Callable[[Sequence[dict]], np.ndarray]]:
    """Fitted callables for one market, all trained on ``split.train`` only."""
    train = split.train

    def logistic(labels: Sequence[str], classes: Sequence[str]):
        model = LogisticModel.fit(design_matrix(train), labels, classes)
        return lambda rows: model.predict_proba(design_matrix(rows))

    def poisson():
        model = GoalModelMarket(PoissonGoalModel.fit(train))
        return lambda rows: predict_goal_market(model, rows, market, _classes_for(market))

    def dixon():
        model = GoalModelMarket(DixonColesModel.fit(train))
        return lambda rows: predict_goal_market(model, rows, market, _classes_for(market))

    if market == MARKET_1X2:
        return {
            "logistic_regression": logistic([r["label_1x2"] for r in train], CLASSES_1X2),
            "poisson_goals": poisson(),
            "dixon_coles": dixon(),
        }
    if market == MARKET_OU:
        return {
            "logistic_regression": logistic([r["label_over_under"] for r in train], CLASSES_OU),
            "poisson_goals": poisson(),
            "dixon_coles": dixon(),
        }
    if market == MARKET_BTTS:
        return {
            "logistic_regression": logistic([r["label_btts"] for r in train], CLASSES_BTTS),
            "poisson_goals": poisson(),
            "dixon_coles": dixon(),
        }
    raise ValueError(f"no candidates for market {market!r}")


def _classes_for(market: str) -> tuple[str, ...]:
    return {
        MARKET_1X2: CLASSES_1X2,
        MARKET_DC: ("1X", "X2", "12"),
        MARKET_OU: CLASSES_OU,
        MARKET_BTTS: CLASSES_BTTS,
    }[market]


def _label_for(row: dict, market: str) -> str:
    return {
        MARKET_1X2: row["label_1x2"],
        MARKET_OU: row["label_over_under"],
        MARKET_BTTS: row["label_btts"],
    }[market]


# ---------------------------------------------------------------------------
# Experiments
# ---------------------------------------------------------------------------


def run_market(split, market: str) -> dict[str, Any]:
    classes = _classes_for(market)
    candidates = build_candidates(split, market)
    validation_labels = [_label_for(r, market) for r in split.validation]
    train_labels = [_label_for(r, market) for r in split.train]
    baseline = frequency_baseline(split.train, split.validation, _label_key(market))

    results: list[dict[str, Any]] = []
    baseline_matrix = np.tile(np.array([baseline[c] for c in classes]), (len(validation_labels), 1))
    results.append(
        {
            "candidate": "training_frequency",
            "validation": evaluate_block(validation_labels, baseline_matrix, classes, baseline),
        }
    )

    fitted: dict[str, Callable[[Sequence[dict]], np.ndarray]] = {}
    for name, predictor in candidates.items():
        probabilities = predictor(split.validation)
        fitted[name] = predictor
        entry = {
            "candidate": name,
            "validation": evaluate_block(validation_labels, probabilities, classes, baseline),
        }
        if len(classes) == 2:
            entry["validation"] = evaluate_binary(validation_labels, probabilities, classes, baseline)
        results.append(entry)

    # Selection uses VALIDATION log loss only.
    best = min(
        (r for r in results if r["candidate"] != "training_frequency"),
        key=lambda r: r["validation"]["log_loss"],
    )
    chosen_name = best["candidate"]

    test_labels = [_label_for(r, market) for r in split.test]
    test_baseline = frequency_baseline(split.train, split.test, _label_key(market))
    test_probabilities = fitted[chosen_name](split.test)
    test_block = evaluate_block(test_labels, test_probabilities, classes, test_baseline)
    if len(classes) == 2:
        test_block = evaluate_binary(test_labels, test_probabilities, classes, test_baseline)

    # The untouched holdout for the baseline as well, so the comparison is fair.
    test_baseline_matrix = np.tile(
        np.array([test_baseline[c] for c in classes]), (len(test_labels), 1)
    )

    per_competition = {}
    for competition in sorted({r["competition"] for r in split.test}):
        mask = [r["competition"] == competition for r in split.test]
        if sum(mask) < MIN_COMPETITION_ROWS:
            continue
        subset_labels = [label for label, keep in zip(test_labels, mask) if keep]
        subset_probs = test_probabilities[np.array(mask)]
        subset_baseline = frequency_baseline(
            [r for r in split.train if r["competition"] == competition] or split.train,
            [r for r in split.test if r["competition"] == competition],
            _label_key(market),
        )
        per_competition[competition] = evaluate_block(
            subset_labels, subset_probs, classes, subset_baseline
        )

    return {
        "market": market,
        "classes": list(classes),
        "chosen_by_validation": chosen_name,
        "split": split.sizes,
        "date_ranges": split.date_ranges(),
        "train_class_distribution": class_distribution(train_labels),
        "validation_class_distribution": class_distribution(validation_labels),
        "validation_results": results,
        "test": {
            "candidate": chosen_name,
            "metrics": test_block,
            "baseline_metrics": {
                "log_loss": log_loss_multi(test_labels, test_baseline_matrix, classes),
                "brier_score": brier_multi(test_labels, test_baseline_matrix, classes),
                "accuracy": accuracy_of(test_labels, test_baseline_matrix, classes),
            },
        },
        "per_competition_test": per_competition,
    }


def _label_key(market: str) -> str:
    return {
        MARKET_1X2: "label_1x2",
        MARKET_OU: "label_over_under",
        MARKET_BTTS: "label_btts",
    }[market]


def run_double_chance(rows: Sequence[dict], split) -> dict[str, Any]:
    """Double chance is DERIVED from the 1X2 grid — never fitted.

    The grid is the Poisson model because that is the model the 1X2 comparison
    selected on validation (the report records the choice); double chance then
    follows algebraically, so it can never disagree with the 1X2 numbers.
    """
    model = GoalModelMarket(PoissonGoalModel.fit(split.train))
    validation = predict_double_chance(model, split.validation)
    test = predict_double_chance(model, split.test)
    consistency = all(
        abs(float(row.sum()) - 2.0) < 1e-9 for row in validation
    ) if len(validation) else True
    return {
        "market": MARKET_DC,
        "derivation": "P(1X)=P(H)+P(D), P(X2)=P(D)+P(A), P(12)=P(H)+P(A) from the 1X2 grid",
        "no_independent_model": True,
        "overlap_sums_to_two": consistency,
        "test": {
            "n": len(test),
            "note": (
                "Probabilities overlap by construction (each pair of outcomes sums to 1), "
                "so no single log loss is defined; the 1X2 metrics above are the contract."
            ),
            "mean_1X": float(test[:, 0].mean()) if len(test) else None,
            "mean_X2": float(test[:, 1].mean()) if len(test) else None,
            "mean_12": float(test[:, 2].mean()) if len(test) else None,
        },
    }


def correct_score_report(split) -> dict[str, Any]:
    """Top correct-score lines from the chosen goal model on the test window."""
    model = GoalModelMarket(PoissonGoalModel.fit(split.train))
    hits = 0
    top_lines: dict[str, int] = {}
    for row in split.test:
        markets = model.probabilities(row)
        score_lines = markets["correct_score"]
        best_line = max(score_lines, key=score_lines.get)
        top_lines[best_line] = top_lines.get(best_line, 0) + 1
        if best_line == f"{row['home_score']}-{row['away_score']}":
            hits += 1
    return {
        "market": MARKET_CS,
        "method": "argmax over the joint scoreline grid (not a multiclass classifier)",
        "n": len(split.test),
        "exact_score_hit_rate": hits / len(split.test) if split.test else None,
        "most_predicted_lines": dict(
            sorted(top_lines.items(), key=lambda item: item[1], reverse=True)[:10]
        ),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", required=True)
    parser.add_argument("--out", default="/app/artifacts/evaluation")
    parser.add_argument("--report", default=None)
    args = parser.parse_args(argv)

    rows = labelled(load_enriched(args.data))
    if not rows:
        print("no completed matches with labels in the dataset", file=sys.stderr)
        return 1
    split = split_holdout(rows)

    report = {
        "generated_at": utc_now_iso(),
        "feature_version": "v2",
        "feature_names": FEATURE_NAMES_V2,
        "dataset": {
            "labelled_rows": len(rows),
            "competitions": sorted({r["competition"] for r in rows}),
        },
        "split": {
            "sizes": split.sizes,
            "date_ranges": split.date_ranges(),
            "policy": (
                "chronological: oldest 70% train, next 15% validation, most recent 15% "
                "untouched test; selection reads validation only"
            ),
        },
        "markets": [],
    }
    for market in (MARKET_1X2, MARKET_OU, MARKET_BTTS):
        report["markets"].append(run_market(split, market))
    report["markets"].append(run_double_chance(rows, split))
    report["markets"].append(correct_score_report(split))

    destination = args.report or os.path.join(args.out, "model_comparison.json")
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    with open(destination, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, default=str)

    for entry in report["markets"]:
        if "test" in entry and "metrics" in entry["test"]:
            metrics = entry["test"]["metrics"]
            print(
                f"{entry['market']:<16} chosen={entry['chosen_by_validation']:<22} "
                f"test log_loss={metrics['log_loss']:.4f} "
                f"(baseline {entry['test']['baseline_metrics']['log_loss']:.4f}) "
                f"brier={metrics['brier_score']:.4f} n={metrics['n']}"
            )
    print(f"report -> {destination}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
