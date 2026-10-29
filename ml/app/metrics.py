"""Prediction metrics: accuracy, multiclass log loss, multiclass Brier score.

Real values are computed where possible; where a metric cannot be meaningfully
computed for tiny fixtures it raises instead of reporting an unavailable result
as a fabricated number.
"""
from __future__ import annotations

import numpy as np

_CLASSES = ["H", "D", "A"]


class MetricError(RuntimeError):
    """Raised when metrics cannot be meaningfully computed."""


def _reorder_proba(
    y_proba: np.ndarray,
    native_classes: list[str],
    target_classes: list[str],
) -> np.ndarray:
    """Reorder probability columns from native sklearn ``classes_`` order
    to the specified target class order.

    sklearn's classifier sorts classes alphabetically, so this reordering
    ensures probabilities are indexed correctly regardless of class count.
    """
    if len(native_classes) != len(target_classes):
        raise MetricError(
            f"expected {len(target_classes)} native classes, got {len(native_classes)}"
        )
    if set(native_classes) != set(target_classes):
        raise MetricError(
            f"native classes {native_classes} do not match expected {target_classes}"
        )
    col_idx = [list(native_classes).index(label) for label in target_classes]
    return y_proba[:, col_idx]


def _reorder_proba_to_canonical(
    y_proba: np.ndarray,
    native_classes: list[str],
) -> np.ndarray:
    """Reorder probability columns from native sklearn ``classes_`` order
    to canonical ``H`` / ``D`` / ``A`` order.

    sklearn's ``HistGradientBoostingClassifier`` sorts classes alphabetically,
    so its ``predict_proba`` columns are ``['A', 'D', 'H']``. Without this
    reordering, evaluation would index probabilities with the wrong columns.
    """
    return _reorder_proba(y_proba, native_classes, list(_CLASSES))


def accuracy(y_true: np.ndarray, y_pred: np.ndarray) -> float:
    if y_true.shape != y_pred.shape:
        raise MetricError("y_true and y_pred shapes must match")
    if y_true.size == 0:
        raise MetricError("no samples for accuracy")
    return float(np.mean(y_true == y_pred))


def log_loss(y_true: np.ndarray, y_proba: np.ndarray) -> float:
    if y_proba.shape[1] != len(_CLASSES):
        raise MetricError("y_proba must have three columns for H/D/A")
    if np.any(y_proba <= 0.0):
        raise MetricError("log_loss undefined for zero probabilities")
    class_idx = np.array([_CLASSES.index(c) for c in y_true])
    per_sample = -np.log(y_proba[np.arange(len(y_true)), class_idx])
    return float(np.mean(per_sample))


def brier_score(y_true: np.ndarray, y_proba: np.ndarray) -> float:
    if y_proba.shape[1] != len(_CLASSES):
        raise MetricError("y_proba must have three columns for H/D/A")
    one_hot = np.zeros_like(y_proba)
    class_idx = np.array([_CLASSES.index(c) for c in y_true])
    one_hot[np.arange(len(y_true)), class_idx] = 1.0
    return float(np.mean(np.sum((one_hot - y_proba) ** 2, axis=1)))


def evaluate_predictions(y_true: np.ndarray, y_proba: np.ndarray, y_pred: np.ndarray) -> dict[str, float]:
    """Return accuracy, log_loss and brier_score as a dict.

    Raises MetricError if any input is empty or malformed.
    """
    if y_true.size == 0:
        raise MetricError("no samples for evaluation")
    if y_proba.shape[0] != y_true.size:
        raise MetricError("y_proba row count must match y_true")
    return {
        "accuracy": accuracy(y_true, y_pred),
        "log_loss": log_loss(y_true, y_proba),
        "brier_score": brier_score(y_true, y_proba),
    }


def held_out_metrics(
    y_true: np.ndarray,
    y_proba: np.ndarray,
    y_pred: np.ndarray,
    split_sizes: list[int],
) -> dict[str, float]:
    """Compute metrics on a held-out (validation) subset by split index.

    ``split_sizes`` are train/validation sizes; the last ``split_sizes[-1]`` rows
    are treated as held out. Raises MetricError when fewer than two classes are
    represented in the held-out set, since the metrics would not be meaningful.
    """
    n_val = split_sizes[-1]
    if y_true.size < n_val + 2:
        raise MetricError("insufficient held-out samples for metrics")
    y_true_val = y_true[-n_val:]
    y_proba_val = y_proba[-n_val:]
    y_pred_val = y_pred[-n_val:]
    if len(set(y_true_val.tolist())) < 2:
        raise MetricError("held-out set lacks class diversity for meaningful metrics")
    return evaluate_predictions(y_true_val, y_proba_val, y_pred_val)


def binary_log_loss(
    y_true: np.ndarray,
    y_proba: np.ndarray,
    classes: list[str],
) -> float:
    """Binary log loss for two-class classification.

    Args:
        y_true: Array of true class labels (e.g., "Over"/"Under").
        y_proba: 2D array of probabilities with shape (n_samples, 2).
        classes: Canonical class order, e.g., ["Under", "Over"].

    Returns:
        Mean log loss.
    """
    if len(classes) != 2:
        raise MetricError("binary_log_loss requires exactly 2 classes")
    if y_proba.shape[1] != 2:
        raise MetricError("y_proba must have 2 columns for binary classification")
    if np.any(y_proba <= 0.0):
        raise MetricError("log_loss undefined for zero probabilities")
    class_idx = np.array([classes.index(c) for c in y_true])
    per_sample = -np.log(y_proba[np.arange(len(y_true)), class_idx])
    return float(np.mean(per_sample))


def binary_brier_score(
    y_true: np.ndarray,
    y_proba: np.ndarray,
    classes: list[str],
) -> float:
    """Binary Brier score for two-class classification.

    Args:
        y_true: Array of true class labels.
        y_proba: 2D array of probabilities with shape (n_samples, 2).
        classes: Canonical class order.

    Returns:
        Mean Brier score.
    """
    if len(classes) != 2:
        raise MetricError("binary_brier_score requires exactly 2 classes")
    if y_proba.shape[1] != 2:
        raise MetricError("y_proba must have 2 columns for binary classification")
    one_hot = np.zeros_like(y_proba)
    class_idx = np.array([classes.index(c) for c in y_true])
    one_hot[np.arange(len(y_true)), class_idx] = 1.0
    return float(np.mean(np.sum((one_hot - y_proba) ** 2, axis=1)))


def binary_evaluate_predictions(
    y_true: np.ndarray,
    y_proba: np.ndarray,
    y_pred: np.ndarray,
    classes: list[str],
) -> dict[str, float]:
    """Evaluate binary classification predictions.

    Args:
        y_true: Array of true class labels.
        y_proba: 2D array of probabilities with shape (n_samples, 2).
        y_pred: Array of predicted class labels.
        classes: Canonical class order.

    Returns:
        Dict with accuracy, log_loss, brier_score.
    """
    if y_true.size == 0:
        raise MetricError("no samples for evaluation")
    if y_proba.shape[0] != y_true.size:
        raise MetricError("y_proba row count must match y_true")
    return {
        "accuracy": accuracy(y_true, y_pred),
        "log_loss": binary_log_loss(y_true, y_proba, classes),
        "brier_score": binary_brier_score(y_true, y_proba, classes),
    }


def binary_uniform_baseline(
    y_true: np.ndarray,
    classes: list[str],
) -> dict[str, float]:
    """Uniform baseline: P(class) = 1/2 for all samples.

    Args:
        y_true: Array of true class labels.
        classes: Canonical class order.

    Returns:
        Dict with accuracy, log_loss, brier_score for the uniform baseline.
    """
    n = y_true.size
    if n == 0:
        raise MetricError("no samples for baseline")
    y_proba = np.ones((n, 2)) / 2.0
    # Predict the first class (deterministic tie-break)
    y_pred = np.array([classes[0]] * n)
    return binary_evaluate_predictions(y_true, y_proba, y_pred, classes)


def binary_frequency_baseline(
    y_true: np.ndarray,
    classes: list[str],
) -> dict[str, float]:
    """Frequency baseline: P(class) = training frequency, predict majority class.

    Args:
        y_true: Array of true class labels.
        classes: Canonical class order.

    Returns:
        Dict with accuracy, log_loss, brier_score for the frequency baseline.
    """
    n = y_true.size
    if n == 0:
        raise MetricError("no samples for baseline")
    counts = {c: int(np.sum(y_true == c)) for c in classes}
    total = sum(counts.values())
    if total == 0:
        raise MetricError("no samples for baseline")
    freqs = np.array([counts[c] / total for c in classes])
    y_proba = np.tile(freqs, (n, 1))
    majority = classes[int(np.argmax(freqs))]
    y_pred = np.array([majority] * n)
    return binary_evaluate_predictions(y_true, y_proba, y_pred, classes)
