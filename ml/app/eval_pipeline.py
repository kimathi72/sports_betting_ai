"""Chronological split and evaluation helpers for market models.

TWO SPLITS, DELIBERATELY SEPARATED
----------------------------------
``split_holdout`` produces train / validation / test by DATE, never at random:

    |------ train ------|-- validation --|-- test (untouched holdout) --|

The test window is only read once, by the report, and never by any code that
chooses between models. Model selection (algorithm, hyper-parameter, competition
pooling) reads validation only. This is the difference between "we evaluated on
held-out data" and "we tuned until the holdout looked good".

``perspective_split`` reserves the fixtures after a fixed date as a prospective
evaluation set: those matches did not exist, as results, when the models for the
earlier period would have been trained. It is reported separately because a
prospective period is a stronger claim than a chronological holdout — and this
project never calls a prospective result "profitability" without odds data, which
it does not have.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable, Sequence

import numpy as np

HOLDOUT_FRACTION = 0.15  # of the labelled rows, the most recent 15%
VALIDATION_FRACTION = 0.15  # of the rows before the holdout


@dataclass(frozen=True)
class Split:
    train: list[dict]
    validation: list[dict]
    test: list[dict]

    @property
    def sizes(self) -> dict[str, int]:
        return {
            "train": len(self.train),
            "validation": len(self.validation),
            "test": len(self.test),
        }

    def date_ranges(self) -> dict[str, list[str | None]]:
        def span(rows: Sequence[dict]) -> list[str | None]:
            if not rows:
                return [None, None]
            ordered = sorted(rows, key=lambda r: (r["kickoff_at"], r.get("id") or 0))
            return [ordered[0]["kickoff_at"][:10], ordered[-1]["kickoff_at"][:10]]

        return {name: span(getattr(self, name)) for name in ("train", "validation", "test")}


def chronological(rows: Iterable[dict]) -> list[dict]:
    return sorted(rows, key=lambda r: (r["kickoff_at"], int(r.get("id") or 0)))


def split_holdout(
    labelled_rows: Sequence[dict],
    *,
    holdout_fraction: float = HOLDOUT_FRACTION,
    validation_fraction: float = VALIDATION_FRACTION,
) -> Split:
    """Date-ordered three-way split of rows that carry a label."""
    ordered = chronological(labelled_rows)
    total = len(ordered)
    if total < 30:
        raise ValueError(f"too few labelled rows to split ({total}); need at least 30")
    n_holdout = max(1, int(round(total * holdout_fraction)))
    n_validation = max(1, int(round((total - n_holdout) * validation_fraction)))
    train_end = total - n_holdout - n_validation
    if train_end < 10:
        raise ValueError("not enough training rows after reserving validation and holdout")
    return Split(
        train=ordered[:train_end],
        validation=ordered[train_end : train_end + n_validation],
        test=ordered[train_end + n_validation :],
    )


def perspective_split(labelled_rows: Sequence[dict], cutoff_date: str) -> tuple[list[dict], list[dict]]:
    """Rows before ``cutoff_date`` (development) and on/after it (prospective)."""
    ordered = chronological(labelled_rows)
    before = [r for r in ordered if r["kickoff_at"][:10] < cutoff_date]
    after = [r for r in ordered if r["kickoff_at"][:10] >= cutoff_date]
    return before, after


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------


def log_loss_multi(y_true: Sequence[str], y_proba: np.ndarray, classes: Sequence[str]) -> float:
    index = {label: i for i, label in enumerate(classes)}
    losses = []
    for label, row in zip(y_true, y_proba):
        p = float(row[index[label]])
        losses.append(-math.log(min(max(p, 1e-15), 1.0)))
    return float(np.mean(losses))


def brier_multi(y_true: Sequence[str], y_proba: np.ndarray, classes: Sequence[str]) -> float:
    """Multiclass Brier score: mean squared error against the one-hot target."""
    index = {label: i for i, label in enumerate(classes)}
    one_hot = np.zeros_like(y_proba)
    for row, label in zip(one_hot, y_true):
        row[index[label]] = 1.0
    return float(np.mean(np.sum((y_proba - one_hot) ** 2, axis=1)))


def log_loss_binary(y_true: Sequence[str], y_proba: np.ndarray, classes: Sequence[str]) -> float:
    return log_loss_multi(y_true, y_proba, classes)


def brier_binary(y_true: Sequence[str], y_proba: np.ndarray, classes: Sequence[str]) -> float:
    return brier_multi(y_true, y_proba, classes)


def accuracy_of(y_true: Sequence[str], probabilities: np.ndarray, classes: Sequence[str]) -> float:
    predicted = [classes[int(np.argmax(row))] for row in probabilities]
    return float(np.mean([p == t for p, t in zip(predicted, y_true)]))


def calibration_table(
    y_true: Sequence[str],
    predicted_probability: Sequence[float],
    positive_label: str,
    bins: Sequence[float] = (0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0),
) -> list[dict[str, float]]:
    """Reliability table: predicted vs. observed frequency per probability bin.

    A model can be well ranked and badly calibrated; log loss punishes that but
    does not explain it. This table is what lets a reader see whether "70%" means
    seven times out of ten.
    """
    buckets = [
        {
            "lower": bins[i],
            "upper": bins[i + 1],
            "count": 0,
            "predicted": 0.0,
            "observed": 0.0,
        }
        for i in range(len(bins) - 1)
    ]
    for label, probability in zip(y_true, predicted_probability):
        index = min(int(probability * (len(bins) - 1)), len(bins) - 2)
        bucket = buckets[index]
        bucket["count"] += 1
        bucket["predicted"] += float(probability)
        bucket["observed"] += 1.0 if label == positive_label else 0.0
    table = []
    for bucket in buckets:
        if bucket["count"] == 0:
            continue
        table.append(
            {
                "lower": bucket["lower"],
                "upper": bucket["upper"],
                "count": bucket["count"],
                "predicted": bucket["predicted"] / bucket["count"],
                "observed": bucket["observed"] / bucket["count"],
            }
        )
    return table


def class_distribution(y_true: Sequence[str]) -> dict[str, float]:
    total = len(y_true)
    counts: dict[str, int] = {}
    for label in y_true:
        counts[label] = counts.get(label, 0) + 1
    return {label: count / total for label, count in sorted(counts.items())} if total else {}


def frequency_baseline(train: Sequence[dict], rows: Sequence[dict], label_key: str) -> dict[str, float]:
    """The distribution of the TRAINING labels, applied to every evaluated row.

    This is the honest floor: a model that cannot beat "always predict the training
    base rate" is not adding information, however good its accuracy looks.
    """
    counts: dict[str, int] = {}
    for row in train:
        counts[row[label_key]] = counts.get(row[label_key], 0) + 1
    total = sum(counts.values())
    return {label: count / total for label, count in sorted(counts.items())}


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()
