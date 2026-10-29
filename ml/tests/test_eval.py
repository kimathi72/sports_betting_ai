"""Tests for prediction metrics: accuracy, multiclass log loss, multiclass Brier score.

Where possible real values are computed. Where a metric cannot be meaningfully
computed for tiny fixtures it raises rather than reporting an unavailable result
as a fabricated number.
"""
from __future__ import annotations

import numpy as np
import pytest

from ml.app.metrics import (
    MetricError,
    accuracy,
    brier_score,
    evaluate_predictions,
    log_loss,
    held_out_metrics,
)


def _y_true() -> np.ndarray:
    return np.array(["H", "D", "A", "H", "A"])


def _y_proba() -> np.ndarray:
    # Hand-computed values for the fixture below.
    # preds: [0.6, 0.3, 0.1], [0.7, 0.2, 0.1], [0.1, 0.3, 0.6], [0.4, 0.4, 0.2], [0.2, 0.3, 0.5]
    return np.array(
        [
            [0.6, 0.3, 0.1],
            [0.7, 0.2, 0.1],
            [0.1, 0.3, 0.6],
            [0.4, 0.4, 0.2],
            [0.2, 0.3, 0.5],
        ]
    )


def _y_pred() -> np.ndarray:
    return np.array(["H", "H", "A", "H", "A"])


def test_accuracy() -> None:
    assert accuracy(_y_true(), _y_pred()) == 0.8


def test_log_loss_rejects_zero_probabilities() -> None:
    y_proba = np.array([[0.0, 0.0, 1.0], [0.5, 0.5, 0.0]])
    y_true = np.array(["D", "H"])
    with pytest.raises(MetricError):
        log_loss(y_true, y_proba)


def test_log_loss_hand_computed() -> None:
    y_true = np.array(["H", "D"])
    y_proba = np.array([[0.6, 0.3, 0.1], [0.7, 0.2, 0.1]])
    # Classes are ordered H=0, D=1, A=2
    # True: H at index 0 with p=0.6, D at index 1 with p=0.2
    expected = float(np.mean([-np.log(0.6), -np.log(0.2)]))
    assert log_loss(y_true, y_proba) == pytest.approx(expected, abs=1e-6)


def test_brier_score_multiclass_computed() -> None:
    score = brier_score(_y_true(), _y_proba())
    # Brier = mean over samples of sum over classes of (one_hot - p)^2
    expected = float(np.mean([
        (1 - 0.6) ** 2 + (0 - 0.3) ** 2 + (0 - 0.1) ** 2,
        (0 - 0.7) ** 2 + (1 - 0.2) ** 2 + (0 - 0.1) ** 2,
        (0 - 0.1) ** 2 + (0 - 0.3) ** 2 + (1 - 0.6) ** 2,
        (1 - 0.4) ** 2 + (0 - 0.4) ** 2 + (0 - 0.2) ** 2,
        (0 - 0.2) ** 2 + (0 - 0.3) ** 2 + (1 - 0.5) ** 2,
    ]))
    assert score == pytest.approx(expected, abs=1e-6)


def test_evaluate_predictions_returns_all_three_metrics() -> None:
    result = evaluate_predictions(y_true=_y_true(), y_proba=_y_proba(), y_pred=_y_pred())
    assert set(result.keys()) == {"accuracy", "log_loss", "brier_score"}
    assert result["accuracy"] == pytest.approx(0.8)


def test_held_out_metrics_requires_real_predictions() -> None:
    with pytest.raises(MetricError):
        held_out_metrics(y_true=_y_true(), y_proba=_y_proba(), y_pred=_y_pred(), split_sizes=[4, 1])


def test_evaluate_predictions_rejects_empty() -> None:
    with pytest.raises(MetricError):
        evaluate_predictions(
            y_true=np.array([]), y_proba=np.zeros((0, 3)), y_pred=np.array([])
        )


def test_evaluate_predictions_rejects_shape_mismatch() -> None:
    with pytest.raises(MetricError):
        evaluate_predictions(
            y_true=_y_true(), y_proba=np.zeros((4, 3)), y_pred=_y_pred()
        )


def test_accuracy_rejects_empty() -> None:
    with pytest.raises(MetricError):
        accuracy(np.array([]), np.array([]))


def test_accuracy_rejects_shape_mismatch() -> None:
    with pytest.raises(MetricError):
        accuracy(np.array(["H"]), np.array(["H", "D"]))


# Baseline comparison tests
def test_uniform_baseline_log_loss() -> None:
    """Uniform probabilities should give log_loss = ln(3) for any label distribution."""
    n = 100
    y_true = np.array(["H", "D", "A"] * 33 + ["H"])  # 100 labels
    y_proba = np.ones((n, 3)) / 3.0
    y_pred = np.array(["H"] * n)
    result = evaluate_predictions(y_true, y_proba, y_pred)
    expected_log_loss = float(-np.log(1 / 3.0))  # ln(3)
    expected_brier = 2.0 / 3.0  # mean of (2/3)^2 + (1/3)^2 + (1/3)^2 = 2/3
    assert result["log_loss"] == pytest.approx(expected_log_loss, abs=1e-9)
    assert result["brier_score"] == pytest.approx(expected_brier, abs=1e-9)


def test_training_frequency_baseline() -> None:
    """Baseline using training set class frequencies on validation labels."""
    y_true = np.array(["H", "D", "A", "H", "A"])
    # Training frequencies: H=0.4, D=0.2, A=0.4
    y_proba = np.array([
        [0.4, 0.2, 0.4],
        [0.4, 0.2, 0.4],
        [0.4, 0.2, 0.4],
        [0.4, 0.2, 0.4],
        [0.4, 0.2, 0.4],
    ])
    # Predict most frequent class (tie: H and A both 0.4; pick H)
    y_pred = np.array(["H", "H", "H", "H", "H"])
    result = evaluate_predictions(y_true, y_proba, y_pred)
    # Correct predictions: H(0)=H yes, H(1)=D no, H(2)=A no, H(3)=H yes, H(4)=A no
    assert result["accuracy"] == pytest.approx(0.4)
    # log_loss = mean(-log(0.4), -log(0.2), -log(0.4), -log(0.4), -log(0.4))
    expected_log_loss = float(np.mean([
        -np.log(0.4), -np.log(0.2), -np.log(0.4), -np.log(0.4), -np.log(0.4)
    ]))
    assert result["log_loss"] == pytest.approx(expected_log_loss, abs=1e-9)
    # Brier per sample:
    # H: (1-0.4)^2 + (0-0.2)^2 + (0-0.4)^2 = 0.36 + 0.04 + 0.16 = 0.56
    # D: (0-0.4)^2 + (1-0.2)^2 + (0-0.4)^2 = 0.16 + 0.64 + 0.16 = 0.96
    # A: (0-0.4)^2 + (0-0.2)^2 + (1-0.4)^2 = 0.16 + 0.04 + 0.36 = 0.56
    expected_brier = float(np.mean([0.56, 0.96, 0.56, 0.56, 0.56]))
    assert result["brier_score"] == pytest.approx(expected_brier, abs=1e-9)


# Column ordering regression tests
def test_log_loss_rejects_wrong_column_order() -> None:
    """Log loss with swapped columns should give a different (wrong) result."""
    y_true = np.array(["H", "A"])
    # Column order is H/D/A. True H has prob 0.8 at col 0.
    y_proba_correct = np.array([[0.8, 0.1, 0.1], [0.1, 0.1, 0.8]])
    correct_ll = log_loss(y_true, y_proba_correct)
    # Swapped columns: H/D/A -> A/D/H. Same probabilities but wrong column order.
    y_proba_swapped = np.array([[0.1, 0.1, 0.8], [0.8, 0.1, 0.1]])
    swapped_ll = log_loss(y_true, y_proba_swapped)
    assert correct_ll != swapped_ll  # Ordering matters


def test_brier_score_rejects_wrong_column_order() -> None:
    """Brier score with swapped columns should give a different result."""
    y_true = np.array(["H", "A"])
    y_proba_correct = np.array([[0.8, 0.1, 0.1], [0.1, 0.1, 0.8]])
    correct_bs = brier_score(y_true, y_proba_correct)
    y_proba_swapped = np.array([[0.1, 0.1, 0.8], [0.8, 0.1, 0.1]])
    swapped_bs = brier_score(y_true, y_proba_swapped)
    assert correct_bs != swapped_bs  # Ordering matters