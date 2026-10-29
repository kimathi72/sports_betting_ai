"""Reproducible, leakage-safe chronological evaluation for every market.

WHY A SEPARATE MODULE
---------------------
The training entry point splits 80/20 and reports a single holdout score. That is
fine for producing an artifact but wrong for comparing models: the same rows would
end up being used to choose a model AND to report its quality, which flatters
whatever was chosen. This module builds an explicit THREE-WAY chronological split
with a final holdout that is never touched during selection.

DESIGN RULES (each guarded by tests in ``ml/tests/test_evaluation.py``)
----------------------------------------------------------------------
1. Chronological only. Rows are ordered by kickoff, never shuffled.
2. Features for a target row see ONLY completed matches with strictly earlier
   kickoffs. ``compute_match_features`` enforces this internally; the split here
   never hands it later rows as candidates.
3. Baselines are fit on TRAIN rows only. The majority baseline is the most
   frequent class in train; the frequency baseline is the train class
   distribution. Neither ever looks at validation or test labels.
4. No preprocessing is fitted on validation/test. The logistic regression
   pipeline is fit inside a ``Pipeline`` so scaling cannot leak.
5. The final test partition is scored once per model and reported, never used to
   choose anything.

The module deliberately holds no model logic of its own: every candidate
estimator is supplied by the caller, so comparisons always run on identical
rows with identical featurisation.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Callable, Iterable, Sequence

import numpy as np

from ml.app.features import compute_match_features
from ml.app.model_store import FEATURE_NAMES


class EvaluationError(RuntimeError):
    """Raised when an evaluation cannot be performed honestly."""


CANONICAL_CLASSES = ["H", "D", "A"]


# ---------------------------------------------------------------------------
# Dataset construction
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class EvaluationRow:
    """One labelled target row, with the metadata needed to audit the split."""

    match_id: int
    kickoff_at: str
    y: str
    features: list[float]
    # Identity and result, carried so a candidate that models teams directly
    # (Elo) can be scored on exactly the same rows as the feature-based ones.
    # Never used by the feature models, which read ``features`` only.
    home_team_id: int | None = None
    away_team_id: int | None = None
    home_score: int | None = None
    away_score: int | None = None


def _sorted_matches(matches: Sequence[dict]) -> list[dict]:
    return sorted(matches, key=lambda m: (m.get("kickoff_at") or "", m.get("id") or 0))


def label_1x2(match: dict) -> str:
    """Home/draw/away from the final score. Never from a pre-computed field."""
    home, away = match.get("home_score"), match.get("away_score")
    if home is None or away is None:
        raise EvaluationError(f"match {match.get('id')} has no final score")
    if home > away:
        return "H"
    if home == away:
        return "D"
    return "A"


def label_over_under(match: dict, line: float = 2.5) -> str:
    """'Over' when total goals exceed the line, else 'Under'."""
    home, away = match.get("home_score"), match.get("away_score")
    if home is None or away is None:
        raise EvaluationError(f"match {match.get('id')} has no final score")
    return "Over" if (home + away) > line else "Under"


def label_btts(match: dict) -> str:
    """'Yes' when both sides scored."""
    home, away = match.get("home_score"), match.get("away_score")
    if home is None or away is None:
        raise EvaluationError(f"match {match.get('id')} has no final score")
    return "Yes" if home > 0 and away > 0 else "No"


MARKET_LABELS: dict[str, Callable[[dict], str]] = {
    "1x2": label_1x2,
    "over_under_2.5": label_over_under,
    "btts": label_btts,
}


def build_rows(matches: Sequence[dict], market: str) -> list[EvaluationRow]:
    """Build labelled feature rows in chronological order.

    A row is emitted only for a completed match with both scores. Its features are
    computed from ``sorted_matches[:i]`` — the same guarantee the production
    training path uses — so no future result can influence an earlier row.
    """
    labeller = MARKET_LABELS.get(market)
    if labeller is None:
        raise EvaluationError(f"unsupported market {market!r}")

    ordered = _sorted_matches(matches)
    rows: list[EvaluationRow] = []

    for index, match in enumerate(ordered):
        if match.get("status") != "completed":
            continue
        if match.get("home_score") is None or match.get("away_score") is None:
            continue

        features = compute_match_features(match, history=ordered[:index])
        rows.append(
            EvaluationRow(
                match_id=int(match.get("id")),
                kickoff_at=str(match.get("kickoff_at") or ""),
                y=labeller(match),
                features=[float(features[name]) for name in FEATURE_NAMES],
                home_team_id=match.get("home_team_id"),
                away_team_id=match.get("away_team_id"),
                home_score=match.get("home_score"),
                away_score=match.get("away_score"),
            )
        )

    if not rows:
        raise EvaluationError(f"no completed matches available for {market}")

    return rows


# ---------------------------------------------------------------------------
# Splitting
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Split:
    """Three chronological partitions of the same rows."""

    train: list[EvaluationRow]
    validation: list[EvaluationRow]
    test: list[EvaluationRow]

    def describe(self) -> dict:
        return {
            "n_train": len(self.train),
            "n_validation": len(self.validation),
            "n_test": len(self.test),
            "train_range": _range(self.train),
            "validation_range": _range(self.validation),
            "test_range": _range(self.test),
        }


def _range(rows: Sequence[EvaluationRow]) -> list[str]:
    if not rows:
        return []
    return [rows[0].kickoff_at, rows[-1].kickoff_at]


def chronological_split(
    rows: Sequence[EvaluationRow],
    validation_fraction: float = 0.2,
    test_fraction: float = 0.2,
) -> Split:
    """Split by time into train / validation / test, preserving order.

    The final ``test_fraction`` is reserved and must not be used for selection.
    Simultaneous kickoffs are kept together: a boundary is only placed between
    rows whose kickoff differs, so two matches kicking off at the same instant
    never straddle train and test. That would leak a same-round result into
    training.
    """
    # Sort defensively: a caller may hold a shuffled list, and splitting by list
    # position would then leak future rows into training. Chronology is the
    # contract, not the caller's ordering.
    rows = sorted(rows, key=lambda row: (row.kickoff_at, row.match_id))

    if validation_fraction <= 0 or test_fraction <= 0:
        raise EvaluationError("validation and test fractions must be positive")
    if validation_fraction + test_fraction >= 1:
        raise EvaluationError("validation + test fractions must leave a train set")

    n = len(rows)
    if n < 30:
        raise EvaluationError(f"too few rows for a three-way split ({n} < 30)")

    test_start = _boundary_at_or_after(rows, int(n * (1 - test_fraction)))
    validation_start = _boundary_at_or_after(rows, int(n * (1 - test_fraction - validation_fraction)))

    train = list(rows[:validation_start])
    validation = list(rows[validation_start:test_start])
    test = list(rows[test_start:])

    if not train or not validation or not test:
        raise EvaluationError(
            f"split produced an empty partition (train={len(train)}, "
            f"validation={len(validation)}, test={len(test)})"
        )

    return Split(train=train, validation=validation, test=test)


def _boundary_at_or_after(rows: Sequence[EvaluationRow], index: int) -> int:
    """Move ``index`` forward until it no longer splits simultaneous kickoffs."""
    index = max(index, 0)
    while 0 < index < len(rows) and rows[index].kickoff_at == rows[index - 1].kickoff_at:
        index += 1
    return index


# ---------------------------------------------------------------------------
# Baselines
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Baseline:
    """A class-distribution predictor fit on TRAIN labels only."""

    name: str
    distribution: dict[str, float]

    @classmethod
    def majority(cls, train: Sequence[EvaluationRow]) -> "Baseline":
        counts = _class_counts(train)
        winner = max(counts, key=counts.get)
        return cls(name="majority", distribution={winner: 1.0})

    @classmethod
    def frequency(cls, train: Sequence[EvaluationRow]) -> "Baseline":
        counts = _class_counts(train)
        total = sum(counts.values())
        return cls(name="frequency", distribution={k: v / total for k, v in counts.items()})

    def predict_proba(
        self, rows: Sequence[EvaluationRow], classes: Sequence[str] | None = None
    ) -> np.ndarray:
        """Return the same distribution for every row.

        The distribution was computed from train labels, so calling this on test
        rows never consults their outcomes.

        ``classes`` forces the output column order. Without it a majority baseline
        would emit a single column and the caller's label indices would not line
        up — the bug this parameter exists to prevent.
        """
        order = list(classes) if classes is not None else self._classes()
        vector = np.array([self.distribution.get(c, 0.0) for c in order])
        return np.tile(vector, (len(rows), 1))

    def _classes(self) -> list[str]:
        # Union of canonical 1X2 classes and whatever was seen, order-preserved.
        seen = [c for c in CANONICAL_CLASSES if c in self.distribution]
        extra = [c for c in sorted(self.distribution) if c not in seen]
        return seen + extra


def _class_counts(rows: Sequence[EvaluationRow]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for row in rows:
        counts[row.y] = counts.get(row.y, 0) + 1
    return counts


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

def _as_matrix(rows: Sequence[EvaluationRow]) -> tuple[np.ndarray, np.ndarray, list[str]]:
    """Feature matrix, labels and the class order used for probabilities."""
    classes = sorted({row.y for row in rows})
    X = np.array([row.features for row in rows], dtype=float)
    y = np.array([row.y for row in rows], dtype=object)
    return X, y, classes


def per_row_log_loss(y_true: Sequence[str], proba: np.ndarray, classes: Sequence[str]) -> np.ndarray:
    """Log loss contributed by each row, in ``y_true`` order.

    Paired comparisons and bootstrap intervals need the per-row losses, not just
    the mean: pairing on the same row is what removes the huge variance that
    comes from comparing two means computed over different samples.
    """
    eps = 1e-15
    index = {c: i for i, c in enumerate(classes)}
    losses = np.empty(len(y_true), dtype=float)
    for position, (truth, probs) in enumerate(zip(y_true, proba)):
        if truth not in index:
            raise EvaluationError(f"label {truth!r} not present in class list")
        p = float(np.asarray(probs)[index[truth]])
        losses[position] = -np.log(min(max(p, eps), 1.0))
    return losses


def log_loss(y_true: Sequence[str], proba: np.ndarray, classes: Sequence[str]) -> float:
    """Multiclass log loss. Raises on degenerate input rather than guessing."""
    return float(per_row_log_loss(y_true, proba, classes).mean())


def brier_score(y_true: Sequence[str], proba: np.ndarray, classes: Sequence[str]) -> float:
    """Multiclass Brier score.

    Definition used throughout this module (Keating's multi-category form, also
    called the "sum" variant):

        Brier = (1/N) * sum_i sum_k (p_ik - y_ik)^2

    where ``y_ik`` is 1 when row i has class k and 0 otherwise, and the sum over
    k runs over the full class list. Lower is better; 0 is perfect.

    Implications an operator must know before quoting a number:
    - It is NOT scaled by the number of classes, so it is only comparable
      between models scored on the SAME class list. Never compare a 3-class
      Brier with a 2-class one.
    - For K classes the value lies in [0, 2], because each row's squared error
      is sum_k p_ik^2 - 2 p_i,truth + 1.
    - With K = 2 it reduces to the familiar 2 * (p - y)^2 for the positive
      class, i.e. twice the textbook binary Brier. That factor is why binary
      markets look worse than the 0-1 range suggests.
    """
    index = {c: i for i, c in enumerate(classes)}
    total = 0.0
    for truth, probs in zip(y_true, proba):
        target = np.zeros(len(classes))
        target[index[truth]] = 1.0
        total += float(np.sum((np.asarray(probs)[: len(classes)] - target) ** 2))
    return total / len(y_true)


def accuracy(y_true: Sequence[str], proba: np.ndarray, classes: Sequence[str]) -> float:
    predicted = np.array(classes)[np.argmax(np.asarray(proba)[:, : len(classes)], axis=1)]
    return float(np.mean(predicted == np.array(y_true)))


def calibration_table(
    y_true: Sequence[str], proba: np.ndarray, classes: Sequence[str], bins: int = 5
) -> list[dict]:
    """Binned reliability for the predicted (modal) outcome.

    For each confidence bin: how often the model was right versus how confident it
    said it was. A well-calibrated model has accuracy ≈ mean confidence.
    """
    maxima = np.max(proba, axis=1)
    predicted = np.argmax(proba, axis=1)
    truth = np.array([classes.index(t) for t in y_true])

    edges = np.linspace(1.0 / len(classes), 1.0, bins + 1)
    table: list[dict] = []

    for low, high in zip(edges[:-1], edges[1:]):
        mask = (maxima >= low) & (maxima < high if high < 1.0 else maxima <= high)
        count = int(mask.sum())
        if count == 0:
            continue
        correct = int((predicted[mask] == truth[mask]).sum())
        table.append(
            {
                "bin": f"{low:.2f}-{high:.2f}",
                "n": count,
                "mean_confidence": float(maxima[mask].mean()),
                "accuracy": correct / count,
            }
        )

    return table


BRIER_DEFINITION = (
    "mean over rows of sum over classes of (p - y)^2; unscaled sum-variant; "
    "range [0, 2] for K classes; comparable only within the same class list"
)


def evaluate_predictions(
    y_true: Sequence[str], proba: np.ndarray, classes: Sequence[str]
) -> dict:
    """Accuracy, log loss, Brier score and calibration for one model."""
    return {
        "n": len(y_true),
        "accuracy": accuracy(y_true, proba, classes),
        "log_loss": log_loss(y_true, proba, classes),
        "brier_score": brier_score(y_true, proba, classes),
        "calibration": calibration_table(y_true, proba, classes),
    }


# ---------------------------------------------------------------------------
# Comparison harness
# ---------------------------------------------------------------------------

@dataclass
class ModelReport:
    name: str
    market: str
    metrics: dict
    split: dict
    class_distribution: dict
    notes: str = ""
    extra: dict = field(default_factory=dict)


def reorder_proba(proba: np.ndarray, native_classes: Sequence[str], target: Sequence[str]) -> np.ndarray:
    """Reorder probability columns into ``target`` order."""
    if set(native_classes) != set(target):
        raise EvaluationError(
            f"native classes {list(native_classes)} do not match target {list(target)}"
        )
    idx = [list(native_classes).index(c) for c in target]
    return np.asarray(proba)[:, idx]


def compare_models(
    split: Split,
    market: str,
    candidates: Iterable[tuple[str, Callable[[Sequence[EvaluationRow]], Callable[[Sequence[EvaluationRow]], np.ndarray]]]],
    *,
    classes: Sequence[str] | None = None,
    baseline: str = "frequency",
    bootstrap_resamples: int = 2000,
) -> list[ModelReport]:
    """Score every candidate on the SAME partitions.

    ``candidates`` is a sequence of ``(name, factory)`` where ``factory(train)``
    returns a callable mapping rows to probabilities with columns in ``classes``
    order. Factories receive only train rows, so nothing may be fitted on
    validation or test data by construction.

    Probabilities are retained per partition so each candidate can be compared
    with the baseline on identical rows (paired), rather than by subtracting two
    independently computed means.
    """
    class_order = list(classes) if classes else sorted({row.y for row in split.train})

    reports: list[ModelReport] = []
    split_summary = split.describe()
    probabilities: dict[str, dict[str, np.ndarray]] = {}

    for name, factory in candidates:
        predict = factory(split.train)

        validation_metrics, validation_proba = _metrics_for(split.validation, predict, class_order)
        test_metrics, test_proba = _metrics_for(split.test, predict, class_order)
        probabilities[name] = {"validation": validation_proba, "test": test_proba}

        reports.append(
            ModelReport(
                name=name,
                market=market,
                metrics={
                    "validation": validation_metrics,
                    "test": test_metrics,
                },
                split=split_summary,
                class_distribution=_distribution(split.test),
            )
        )

    if reports and baseline in probabilities:
        for partition, rows in (("validation", split.validation), ("test", split.test)):
            y_true = [row.y for row in rows]
            probas = {name: p[partition] for name, p in probabilities.items()}
            deltas = compare_against_baseline(
                y_true, probas, class_order, baseline=baseline, resamples=bootstrap_resamples
            )
            for report in reports:
                if report.name in deltas:
                    report.metrics[partition]["log_loss_delta_vs_baseline"] = deltas[report.name]

    return reports


def _metrics_for(
    rows: Sequence[EvaluationRow], predict, classes: Sequence[str]
) -> tuple[dict, np.ndarray]:
    if not rows:
        raise EvaluationError("cannot score an empty partition")
    proba = np.asarray(predict(rows))
    return evaluate_predictions([row.y for row in rows], proba, list(classes)), proba


# ---------------------------------------------------------------------------
# Paired uncertainty
# ---------------------------------------------------------------------------

def paired_bootstrap_log_loss_delta(
    y_true: Sequence[str],
    proba_model: np.ndarray,
    proba_reference: np.ndarray,
    classes: Sequence[str],
    *,
    resamples: int = 2000,
    seed: int = 20240529,
    confidence: float = 0.95,
) -> dict:
    """Bootstrap interval for (model log loss - reference log loss).

    Rows are resampled with replacement, and BOTH models are scored on the SAME
    resampled rows. That pairing is the whole point: the models differ only in
    their probabilities for an identical fixture, so most of the variance in the
    difference cancels, and the interval reflects the selection question
    ("is this model better?") rather than the difficulty of the fixtures.

    Negative delta favours the model. ``probability_better`` is the share of
    resamples in which the model beat the reference — a plain-English summary,
    but the interval is the honest statement: overlapping zero means the test
    partition cannot separate the two models.

    The seed is fixed, so the same inputs reproduce the same interval exactly.
    """
    if resamples <= 0:
        raise EvaluationError("resamples must be positive")

    n = len(y_true)
    if n == 0:
        raise EvaluationError("cannot bootstrap an empty partition")

    model_loss = per_row_log_loss(y_true, proba_model, classes)
    reference_loss = per_row_log_loss(y_true, proba_reference, classes)
    delta = model_loss - reference_loss

    rng = np.random.default_rng(seed)
    # Draw every resample's row indices at once: deterministic, and the same
    # index matrix is applied to both loss vectors, which is what makes it paired.
    indices = rng.integers(0, n, size=(resamples, n))
    sampled = delta[indices].mean(axis=1)

    alpha = (1.0 - confidence) / 2.0
    low, high = np.quantile(sampled, [alpha, 1.0 - alpha])

    return {
        "observed_delta": float(delta.mean()),
        "ci_low": float(low),
        "ci_high": float(high),
        "confidence": float(confidence),
        "resamples": int(resamples),
        "seed": int(seed),
        "probability_better": float(np.mean(sampled < 0.0)),
        "n": int(n),
    }


def compare_against_baseline(
    y_true: Sequence[str],
    probas: dict[str, np.ndarray],
    classes: Sequence[str],
    *,
    baseline: str = "frequency",
    resamples: int = 2000,
) -> dict:
    """Log-loss delta versus one baseline, with a paired bootstrap interval per model."""
    if baseline not in probas:
        raise EvaluationError(f"baseline {baseline!r} not among candidates {list(probas)}")

    reference = np.asarray(probas[baseline])
    out: dict[str, dict] = {}
    for name, proba in probas.items():
        if name == baseline:
            continue
        out[name] = paired_bootstrap_log_loss_delta(
            y_true, np.asarray(proba), reference, classes, resamples=resamples
        )
    return out


def _distribution(rows: Sequence[EvaluationRow]) -> dict[str, int]:
    return dict(sorted(_class_counts(rows).items()))


def report_to_json(reports: Sequence[ModelReport], extra: dict | None = None) -> dict:
    """Machine-readable report, with everything needed to reproduce a run."""
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "evaluation_method": (
            "chronological three-way split; final test held out from selection; "
            "baselines fit on train labels only; no shuffling"
        ),
        "metric_definitions": {
            "log_loss": "mean negative log probability of the true class (multiclass)",
            "brier_score": BRIER_DEFINITION,
            "log_loss_delta_vs_baseline": (
                "model log loss minus baseline log loss on the same partition; "
                "negative is better than the baseline"
            ),
        },
        "market": reports[0].market if reports else None,
        "split": reports[0].split if reports else {},
        "class_distribution_test": reports[0].class_distribution if reports else {},
        "models": [
            {
                "name": r.name,
                "metrics": r.metrics,
                "notes": r.notes,
                **r.extra,
            }
            for r in reports
        ],
        **(extra or {}),
    }
