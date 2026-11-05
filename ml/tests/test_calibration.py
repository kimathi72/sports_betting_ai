"""Calibration infrastructure.

These tests use synthetic probabilities with known distortion, so the assertion is
about behaviour rather than about a particular model's numbers:
  - an over-confident predictor should be improved by calibration;
  - an already-calibrated predictor should not be made worse by much;
  - a calibrator must never be assessed on its own fit data.
"""

from __future__ import annotations

import pytest

from app.calibration import (
    CALIBRATORS,
    CalibrationStudy,
    IdentityCalibrator,
    IsotonicCalibrator,
    PlattCalibrator,
    brier_score,
    expected_calibration_error,
    log_loss,
    make_calibrator,
    reliability_table,
)
from app.eval_protocol import (
    CALIBRATION_ASSESSMENT,
    CALIBRATION_FIT,
    PartitionError,
    SpentManifest,
)


def manifest_with(fit_ids, assess_ids):
    entries = [{"match_id": m, "used_for": [CALIBRATION_FIT]} for m in fit_ids]
    entries += [{"match_id": m, "used_for": [CALIBRATION_ASSESSMENT]} for m in assess_ids]
    return SpentManifest(entries=entries)


# --------------------------------------------------------------------------- metrics


def test_log_loss_of_a_confident_correct_prediction_is_small():
    assert log_loss([0.99, 0.99], [1, 1]) < 0.05


def test_log_loss_of_a_confident_wrong_prediction_is_large_but_finite():
    value = log_loss([0.001, 0.001], [1, 1])
    assert value > 5.0
    assert value != float("inf")


def test_log_loss_clips_rather_than_raising_on_probability_zero():
    assert log_loss([0.0, 1.0], [1, 0]) < 100


def test_brier_score_is_zero_for_perfect_predictions():
    assert brier_score([1.0, 0.0], [1, 0]) == pytest.approx(0.0)


def test_brier_score_is_maximal_for_confidently_wrong_predictions():
    assert brier_score([0.0, 1.0], [1, 0]) == pytest.approx(1.0)


def test_ece_is_near_zero_for_a_perfectly_calibrated_set():
    # In each bin the predicted mean equals the observed frequency.
    probabilities = [0.1] * 100 + [0.9] * 100
    outcomes = [1] * 10 + [0] * 90 + [1] * 90 + [0] * 10

    assert expected_calibration_error(probabilities, outcomes, bins=10) < 0.02


def test_ece_is_large_when_probabilities_are_overconfident():
    probabilities = [0.9] * 100
    outcomes = [1] * 50 + [0] * 50  # true rate is 0.5, not 0.9

    assert expected_calibration_error(probabilities, outcomes, bins=10) > 0.3


def test_reliability_table_accounts_for_every_observation():
    probabilities = [0.05, 0.25, 0.35, 0.65, 0.85]
    outcomes = [0, 1, 0, 1, 1]

    table = reliability_table(probabilities, outcomes, bins=10)

    assert sum(row["count"] for row in table) == len(probabilities)


def test_ece_refuses_an_empty_sample_instead_of_returning_zero():
    with pytest.raises(ValueError):
        expected_calibration_error([], [])


# --------------------------------------------------------------------------- methods


def test_the_identity_calibrator_returns_the_input_unchanged():
    calibrated = IdentityCalibrator().transform([0.2, 0.5, 0.9])
    assert list(calibrated) == pytest.approx([0.2, 0.5, 0.9])


def test_platt_learns_to_reduce_overconfidence():
    # Truth is 50%, model says 90%: the fitted mapping must pull it down.
    calibrated = PlattCalibrator().fit([0.9] * 200, [1] * 100 + [0] * 100)
    adjusted = calibrated.transform([0.9])[0]

    assert adjusted < 0.9
    assert 0.3 < adjusted < 0.7


def test_platt_leaves_a_well_calibrated_model_roughly_alone():
    probabilities = [0.2] * 100 + [0.8] * 100
    outcomes = [1] * 20 + [0] * 80 + [1] * 80 + [0] * 20

    adjusted = PlattCalibrator().fit(probabilities, outcomes).transform([0.2, 0.8])

    assert adjusted[0] == pytest.approx(0.2, abs=0.1)
    assert adjusted[1] == pytest.approx(0.8, abs=0.1)


def test_isotonic_is_monotonic_even_when_the_data_is_noisy():
    probabilities = [0.1, 0.4, 0.35, 0.8, 0.2]
    outcomes = [0, 1, 0, 1, 0]  # deliberately non-monotone

    calibrated = IsotonicCalibrator().fit(probabilities, outcomes).transform(
        [0.1, 0.2, 0.35, 0.4, 0.8]
    )

    assert all(a <= b + 1e-12 for a, b in zip(calibrated, calibrated[1:]))


def test_an_unknown_method_is_rejected_by_name():
    with pytest.raises(ValueError, match="unknown calibration method"):
        make_calibrator("magic")


def test_every_registered_calibrator_exposes_fit_transform_and_parameters():
    for name in CALIBRATORS:
        calibrator = make_calibrator(name)
        calibrator.fit([0.3, 0.6, 0.9], [0, 1, 1])
        assert calibrator.transform([0.5]) is not None
        assert calibrator.to_dict()["method"] == name


# --------------------------------------------------------------------------- study


def test_a_study_refuses_overlapping_fit_and_assessment():
    """The rule the whole phase exists to enforce."""
    with pytest.raises(PartitionError) as exc:
        CalibrationStudy(
            manifest=manifest_with([1, 2], [1, 3]),
            fit_ids=[1, 2],
            assess_ids=[1, 3],
        )

    assert "1" in str(exc.value)


def test_a_study_refuses_an_empty_partition():
    with pytest.raises(PartitionError):
        CalibrationStudy(manifest=SpentManifest(), fit_ids=[], assess_ids=[1])
    with pytest.raises(PartitionError):
        CalibrationStudy(manifest=SpentManifest(), fit_ids=[1], assess_ids=[])


def test_a_study_compares_methods_on_disjoint_partitions():
    fit_ids = list(range(100))
    assess_ids = list(range(100, 200))
    study = CalibrationStudy(
        manifest=manifest_with(fit_ids, assess_ids),
        fit_ids=fit_ids,
        assess_ids=assess_ids,
    )

    # Over-confident model: true rate 0.5 wherever it says 0.9.
    results = study.compare(
        fit_probabilities=[0.9] * 100,
        fit_outcomes=[1] * 50 + [0] * 50,
        assess_probabilities=[0.9] * 100,
        assess_outcomes=[1] * 50 + [0] * 50,
    )

    by_method = {r.method: r for r in results}
    assert set(by_method) == {"identity", "platt", "isotonic"}
    # Calibrated variants must beat the uncalibrated baseline on the held-out set.
    assert by_method["platt"].log_loss < by_method["identity"].log_loss
    assert by_method["platt"].n_fit == 100
    assert by_method["platt"].n_assess == 100


def test_a_study_rejects_probabilities_that_do_not_match_the_declared_ids():
    study = CalibrationStudy(manifest=SpentManifest(), fit_ids=[1, 2], assess_ids=[3])

    with pytest.raises(ValueError):
        study.compare(
            fit_probabilities=[0.5],
            fit_outcomes=[0],
            assess_probabilities=[0.5],
            assess_outcomes=[1],
        )


def test_study_metadata_is_versioned_and_identifies_its_base_model():
    fit_ids, assess_ids = [1, 2, 3], [4, 5, 6]
    study = CalibrationStudy(manifest=SpentManifest(), fit_ids=fit_ids, assess_ids=assess_ids)

    results = study.compare(
        fit_probabilities=[0.9, 0.1, 0.5], fit_outcomes=[1, 0, 1],
        assess_probabilities=[0.9, 0.1, 0.5], assess_outcomes=[1, 0, 0],
        methods=("identity", "platt"),
    )
    meta = study.metadata(
        results,
        base_model="model_1x2.joblib",
        feature_version="v2",
        fit_range="2024-01-01..2024-06-30",
        assess_range="2024-07-01..2024-12-31",
        artifact_sha256="abc123",
    )

    assert meta["base_model"] == "model_1x2.joblib"
    assert meta["n_fit"] == 3 and meta["n_assess"] == 3
    assert {r["method"] for r in meta["results"]} == {"identity", "platt"}
    assert meta["artifact_sha256"] == "abc123"
