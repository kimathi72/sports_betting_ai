"""Leakage and reproducibility guarantees for the evaluation pipeline.

These tests exist to make the *claims* testable: a three-way chronological split,
baselines that never see test labels, and features that cannot incorporate a
future result.
"""
from __future__ import annotations

from datetime import datetime, timedelta

import numpy as np
import pytest

from ml.app.evaluation import (
    Baseline,
    EvaluationError,
    EvaluationRow,
    brier_score,
    build_rows,
    chronological_split,
    compare_models,
    evaluate_predictions,
    label_1x2,
    label_btts,
    label_over_under,
    log_loss,
    paired_bootstrap_log_loss_delta,
    report_to_json,
)
from ml.app.model_store import FEATURE_NAMES


def _match(mid: int, day: int, hs: int, as_: int, status: str = "completed", hour: int = 15) -> dict:
    kickoff = datetime(2020, 1, 1, hour) + timedelta(days=day)
    return {
        "id": mid,
        "kickoff_at": kickoff.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "status": status,
        "home_team_id": 1,
        "away_team_id": 2,
        "home_score": hs,
        "away_score": as_,
    }


def _rows(n: int, start_day: int = 0) -> list[EvaluationRow]:
    return [
        EvaluationRow(
            match_id=i,
            kickoff_at=(datetime(2020, 1, 1) + timedelta(days=start_day + i)).isoformat(),
            y=["H", "D", "A"][i % 3],
            features=[float(i)] * len(FEATURE_NAMES),
        )
        for i in range(n)
    ]


# --- labels -----------------------------------------------------------------

def test_labels_are_derived_from_the_score_not_a_stored_field() -> None:
    assert label_1x2(_match(1, 0, 2, 0)) == "H"
    assert label_1x2(_match(1, 0, 1, 1)) == "D"
    assert label_1x2(_match(1, 0, 0, 3)) == "A"


def test_over_under_uses_the_goal_total() -> None:
    assert label_over_under(_match(1, 0, 2, 1)) == "Over"   # 3 goals
    assert label_over_under(_match(1, 0, 1, 1)) == "Under"  # 2 goals
    assert label_over_under(_match(1, 0, 2, 0)) == "Under"  # exactly 2


def test_btts_requires_both_sides_to_score() -> None:
    assert label_btts(_match(1, 0, 1, 1)) == "Yes"
    assert label_btts(_match(1, 0, 3, 0)) == "No"


def test_label_raises_without_a_final_score() -> None:
    m = _match(1, 0, None, None, status="scheduled")
    with pytest.raises(EvaluationError):
        label_1x2(m)


# --- leakage ----------------------------------------------------------------

def test_a_future_match_cannot_change_an_earlier_rows_features() -> None:
    """The core leakage guard: adding a later result must not alter history."""
    matches = [_match(1, 0, 2, 0), _match(2, 7, 1, 1), _match(3, 14, 0, 3)]

    before = build_rows(matches, "1x2")

    # Append an extreme future result. Earlier rows must be byte-identical.
    after = build_rows(matches + [_match(4, 21, 9, 0)], "1x2")

    for b, a in zip(before, after):
        assert b.features == a.features, f"row {b.match_id} changed when a future match was added"


def test_simultaneous_kickoffs_do_not_leak_into_each_other() -> None:
    """Two matches at the same instant must not see each other's result."""
    same_time = [
        _match(1, 10, 5, 0, hour=15),
        _match(2, 10, 0, 5, hour=15),
        _match(3, 20, 1, 0, hour=15),
    ]

    rows = build_rows(same_time, "1x2")

    # With no STRICTLY earlier history, both simultaneous rows must have
    # identical (empty-history) features.
    assert rows[0].features == rows[1].features


def test_incomplete_matches_are_never_targets() -> None:
    matches = [_match(1, 0, 2, 0), _match(2, 7, 0, 0, status="scheduled")]
    matches[1]["home_score"] = None
    matches[1]["away_score"] = None

    rows = build_rows(matches, "1x2")

    assert [r.match_id for r in rows] == [1]


# --- splitting --------------------------------------------------------------

def test_split_is_chronological_and_disjoint() -> None:
    split = chronological_split(_rows(100))

    assert len(split.train) + len(split.validation) + len(split.test) == 100
    assert split.train[-1].kickoff_at < split.validation[0].kickoff_at
    assert split.validation[-1].kickoff_at < split.test[0].kickoff_at


def test_split_keeps_simultaneous_kickoffs_together() -> None:
    """A boundary must not divide matches that kicked off at the same instant."""
    rows = _rows(100)
    # Force a tie around the expected validation boundary.
    boundary = rows[60]
    rows[59] = EvaluationRow(
        match_id=rows[59].match_id,
        kickoff_at=boundary.kickoff_at,
        y=rows[59].y,
        features=rows[59].features,
    )

    split = chronological_split(rows)

    assert split.train[-1].kickoff_at < split.validation[0].kickoff_at


def test_split_uses_chronology_even_when_input_is_shuffled() -> None:
    rows = _rows(100)
    shuffled = rows[40:] + rows[:40]

    split = chronological_split(shuffled)

    assert split.train[0].kickoff_at <= split.train[-1].kickoff_at
    assert split.train[-1].kickoff_at < split.validation[0].kickoff_at


def test_split_rejects_too_few_rows() -> None:
    with pytest.raises(EvaluationError):
        chronological_split(_rows(10))


def test_split_rejects_degenerate_fractions() -> None:
    with pytest.raises(EvaluationError):
        chronological_split(_rows(100), validation_fraction=0.6, test_fraction=0.6)


# --- baselines --------------------------------------------------------------

def test_majority_baseline_uses_only_train_labels() -> None:
    train = [EvaluationRow(1, "2020-01-01", "H", [0.0] * len(FEATURE_NAMES)),
             EvaluationRow(2, "2020-01-02", "H", [0.0] * len(FEATURE_NAMES)),
             EvaluationRow(3, "2020-01-03", "A", [0.0] * len(FEATURE_NAMES))]
    baseline = Baseline.majority(train)

    assert baseline.distribution == {"H": 1.0}


def test_frequency_baseline_matches_train_distribution() -> None:
    train = [EvaluationRow(i, f"2020-01-0{i+1}", y, [0.0] * len(FEATURE_NAMES))
             for i, y in enumerate(["H", "H", "D", "A"])]

    baseline = Baseline.frequency(train)

    assert baseline.distribution["H"] == pytest.approx(0.5)
    assert baseline.distribution["D"] == pytest.approx(0.25)


def test_baseline_prediction_is_identical_for_every_row() -> None:
    train = [EvaluationRow(1, "2020-01-01", "H", [0.0] * len(FEATURE_NAMES))]
    baseline = Baseline.frequency(train)
    test = _rows(5)

    proba = baseline.predict_proba(test)

    assert np.allclose(proba, proba[0])


# --- metrics ----------------------------------------------------------------

def test_log_loss_is_lower_for_a_better_calibrated_model() -> None:
    y = ["H", "D", "A"]
    good = np.array([[0.8, 0.1, 0.1], [0.1, 0.8, 0.1], [0.1, 0.1, 0.8]])
    bad = np.array([[0.34, 0.33, 0.33]] * 3)

    assert log_loss(y, good, ["H", "D", "A"]) < log_loss(y, bad, ["H", "D", "A"])


def test_metrics_reject_a_label_missing_from_classes() -> None:
    with pytest.raises(EvaluationError):
        log_loss(["X"], np.array([[0.5, 0.5]]), ["H", "A"])


def test_evaluate_predictions_reports_calibration() -> None:
    y = ["H", "H", "A", "D"]
    proba = np.array([[0.9, 0.05, 0.05], [0.8, 0.1, 0.1], [0.2, 0.2, 0.6], [0.3, 0.4, 0.3]])

    metrics = evaluate_predictions(y, proba, ["H", "D", "A"])

    assert set(metrics) == {"n", "accuracy", "log_loss", "brier_score", "calibration"}
    assert metrics["n"] == 4
    # All four rows are predicted correctly: H, H, A, D.
    assert metrics["accuracy"] == pytest.approx(1.0)
    assert metrics["calibration"]


# --- comparison harness -----------------------------------------------------

def test_compare_models_scores_every_candidate_on_the_same_rows() -> None:
    split = chronological_split(_rows(120), validation_fraction=0.2, test_fraction=0.2)

    def constant(prob):
        return lambda train: (lambda rows: np.tile(prob, (len(rows), 1)))

    reports = compare_models(
        split,
        "1x2",
        [
            ("uniform", constant([1 / 3, 1 / 3, 1 / 3])),
            ("home-lean", constant([0.5, 0.25, 0.25])),
        ],
        classes=["H", "D", "A"],
    )

    assert len(reports) == 2
    for report in reports:
        assert report.split["n_test"] == len(split.test)
        assert set(report.metrics) == {"validation", "test"}


def test_factory_never_receives_validation_or_test_rows() -> None:
    """A candidate can only ever be fitted on train, by construction."""
    split = chronological_split(_rows(120))
    seen: list[int] = []

    def factory(train):
        seen.append(len(train))

        def predict(rows):
            return np.tile([1 / 3, 1 / 3, 1 / 3], (len(rows), 1))

        return predict

    compare_models(split, "1x2", [("probe", factory)], classes=["H", "D", "A"])

    assert seen == [len(split.train)]


# --- fair comparison: log-loss delta vs baseline -----------------------------

def test_brier_definition_is_documented_and_is_the_sum_variant() -> None:
    """Hand-computed: perfect prediction scores 0; a 3-class 0/1 guess scores 2."""
    classes = ["H", "D", "A"]

    assert brier_score(["H"], np.array([[1.0, 0.0, 0.0]]), classes) == pytest.approx(0.0)
    # (0-1)^2 + (1-0)^2 + (1-0)^2 = 3 ... over one row, summed across classes.
    assert brier_score(["A"], np.array([[1.0, 0.0, 0.0]]), classes) == pytest.approx(2.0)
    # Uniform: (1/3-1)^2 + (1/3)^2 + (1/3)^2 = 2/3 -> per row.
    assert brier_score(["H"], np.array([[1 / 3, 1 / 3, 1 / 3]]), classes) == pytest.approx(2 / 3)


def test_brier_definition_string_is_reported() -> None:
    from ml.app.evaluation import BRIER_DEFINITION

    assert "sum over classes" in BRIER_DEFINITION
    assert "range [0, 2]" in BRIER_DEFINITION


def test_evaluate_predictions_reports_the_sample_size() -> None:
    metrics = evaluate_predictions(
        ["H", "A"], np.array([[0.9, 0.05, 0.05], [0.1, 0.1, 0.8]]), ["H", "D", "A"]
    )

    assert metrics["n"] == 2


def test_paired_bootstrap_of_identical_models_is_exactly_zero() -> None:
    y = ["H", "D", "A", "H"]
    proba = np.array([[0.6, 0.2, 0.2], [0.2, 0.6, 0.2], [0.2, 0.2, 0.6], [0.5, 0.3, 0.2]])

    result = paired_bootstrap_log_loss_delta(y, proba, proba, ["H", "D", "A"], resamples=200)

    assert result["observed_delta"] == pytest.approx(0.0)
    assert result["ci_low"] == pytest.approx(0.0)
    assert result["ci_high"] == pytest.approx(0.0)


def test_paired_bootstrap_sign_indicates_which_model_is_better() -> None:
    """Delta is model - reference, so a clearly better model gets a negative delta."""
    y = ["H"] * 50
    model = np.array([[0.9, 0.05, 0.05]] * 50)      # much lower loss
    reference = np.array([[0.4, 0.3, 0.3]] * 50)    # much higher loss

    result = paired_bootstrap_log_loss_delta(y, model, reference, ["H", "D", "A"], resamples=200)

    assert result["observed_delta"] < 0
    assert result["ci_high"] < 0, "whole interval below zero => model is better"
    assert result["probability_better"] == pytest.approx(1.0)


def test_paired_bootstrap_is_reproducible_for_a_fixed_seed() -> None:
    rng = np.random.default_rng(0)
    y = ["H", "D", "A"] * 30
    a = rng.dirichlet([1, 1, 1], size=len(y))
    b = rng.dirichlet([1, 1, 1], size=len(y))

    first = paired_bootstrap_log_loss_delta(y, a, b, ["H", "D", "A"], resamples=300, seed=7)
    second = paired_bootstrap_log_loss_delta(y, a, b, ["H", "D", "A"], resamples=300, seed=7)

    assert first == second


def test_paired_bootstrap_uses_the_same_rows_for_both_models() -> None:
    """The point estimate must be the mean PAIRED per-row difference.

    Rows alternate between two fixtures whose deltas differ, so the per-row
    differences are not constant and the interval is properly non-degenerate.
    """
    y = ["H", "A"] * 40
    model = np.array([[0.7, 0.2, 0.1], [0.1, 0.2, 0.7]] * 40)
    reference = np.array([[0.5, 0.3, 0.2], [0.3, 0.3, 0.4]] * 40)

    result = paired_bootstrap_log_loss_delta(y, model, reference, ["H", "D", "A"], resamples=400)

    expected = log_loss(y, model, ["H", "D", "A"]) - log_loss(y, reference, ["H", "D", "A"])
    assert result["observed_delta"] == pytest.approx(expected)
    assert result["ci_low"] < result["observed_delta"] < result["ci_high"]
    assert result["n"] == len(y)


def test_compare_models_attaches_a_delta_for_every_non_baseline_model() -> None:
    split = chronological_split(_rows(120))

    def constant(prob):
        return lambda train: (lambda rows: np.tile(prob, (len(rows), 1)))

    reports = compare_models(
        split,
        "1x2",
        [
            ("frequency", constant([0.44, 0.25, 0.31])),
            ("lean-home", constant([0.60, 0.20, 0.20])),
        ],
        classes=["H", "D", "A"],
        baseline="frequency",
        bootstrap_resamples=100,
    )

    by_name = {r.name: r for r in reports}
    assert "log_loss_delta_vs_baseline" not in by_name["frequency"].metrics["validation"]
    delta = by_name["lean-home"].metrics["test"]["log_loss_delta_vs_baseline"]
    assert delta["n"] == len(split.test)
    assert set(delta) >= {"observed_delta", "ci_low", "ci_high", "probability_better"}


def test_report_documents_the_metric_definitions() -> None:
    split = chronological_split(_rows(60))

    def constant(prob):
        return lambda train: (lambda rows: np.tile(prob, (len(rows), 1)))

    reports = compare_models(
        split, "1x2", [("frequency", constant([0.44, 0.25, 0.31]))], classes=["H", "D", "A"]
    )

    payload = report_to_json(reports)

    assert "brier_score" in payload["metric_definitions"]
    assert "sum over classes" in payload["metric_definitions"]["brier_score"]
