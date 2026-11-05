"""Evaluation protocol and observation-partition integrity.

WHY THIS EXISTS
---------------
The project's test partition was already scored before the harness was revised, so
every "final" number produced so far is exploratory. Re-running the evaluator would
happily score those rows again and present them as fresh evidence.

These tests pin the machinery that prevents that: an authoritative, versioned
protocol; an explicit manifest of which observations have been spent and on what;
and an evaluator gate that refuses to call spent rows an untouched holdout.

All tests are synthetic: no network, no artifacts, no database.
"""

from __future__ import annotations

import json

import pytest

from app.eval_protocol import (
    EVALUATION,
    HOLDOUT,
    MODEL_SELECTION,
    TRAINING,
    PartitionError,
    Protocol,
    ProtocolError,
    SpentManifest,
    partition_for_row,
    require_clean_holdout,
)


# --------------------------------------------------------------------------- fixtures


def manifest(entries=None, **kwargs) -> SpentManifest:
    return SpentManifest(entries=list(entries or []), **kwargs)


# --------------------------------------------------------------------------- protocol


def test_a_protocol_records_every_boundary_it_needs_to_be_reproduced():
    p = Protocol(
        version="v2.1",
        train_end="2023-12-03",
        validation_end="2025-02-26",
        feature_version="v2",
        seeds={"split": 20240529, "bootstrap": 20240529},
        class_orders={"1x2": ["H", "D", "A"]},
    )

    payload = p.to_dict()

    assert payload["version"] == "v2.1"
    assert payload["train_end"] == "2023-12-03"
    assert payload["feature_version"] == "v2"
    assert payload["seeds"]["split"] == 20240529


def test_a_protocol_digest_changes_when_any_boundary_changes():
    base = dict(train_end="2023-12-03", validation_end="2025-02-26",
                feature_version="v2", seeds={"split": 1},
                class_orders={"1x2": ["H", "D", "A"]})
    a = Protocol(version="v1", **base)
    b = Protocol(version="v1", **{**base, "validation_end": "2025-03-01"})
    c = Protocol(version="v1", **{**base, "seeds": {"split": 2}})

    assert a.digest() != b.digest()
    assert a.digest() != c.digest()
    # Same inputs must always produce the same digest.
    assert a.digest() == Protocol(version="v1", **base).digest()


@pytest.mark.parametrize("bad", ["2023/12/03", "03-12-2023", "", None])
def test_a_protocol_rejects_a_date_it_cannot_compare(bad):
    with pytest.raises(ProtocolError):
        Protocol(version="v1", train_end=bad, validation_end="2025-02-26",
                 feature_version="v2", seeds={}, class_orders={})


def test_boundaries_must_be_chronological():
    # A validation window that starts before training ends would silently overlap.
    with pytest.raises(ProtocolError):
        Protocol(version="v1", train_end="2025-02-26", validation_end="2023-12-03",
                 feature_version="v2", seeds={}, class_orders={})


# --------------------------------------------------------------------------- manifest


def test_a_row_before_the_training_cut_is_training_data():
    p = Protocol(version="v1", train_end="2023-12-03", validation_end="2025-02-26",
                 feature_version="v2", seeds={}, class_orders={})

    assert partition_for_row("2021-05-01", p) == TRAINING
    assert partition_for_row("2023-12-03", p) == TRAINING


def test_a_row_between_cuts_is_model_selection_data():
    p = Protocol(version="v1", train_end="2023-12-03", validation_end="2025-02-26",
                 feature_version="v2", seeds={}, class_orders={})

    assert partition_for_row("2024-06-01", p) == MODEL_SELECTION


def test_a_row_after_the_validation_cut_is_holdout():
    p = Protocol(version="v1", train_end="2023-12-03", validation_end="2025-02-26",
                 feature_version="v2", seeds={}, class_orders={})

    assert partition_for_row("2025-06-01", p) == HOLDOUT


def test_the_manifest_reports_rows_already_used_for_evaluation():
    m = manifest([{"match_id": 1, "used_for": [EVALUATION]}])

    assert m.is_spent(1)
    assert not m.is_spent(2)


def test_the_manifest_reports_rows_used_for_training_or_selection():
    m = manifest([
        {"match_id": 1, "used_for": [TRAINING]},
        {"match_id": 2, "used_for": [MODEL_SELECTION]},
    ])

    assert m.is_spent(1)
    assert m.is_spent(2)


# --------------------------------------------------------------------------- the gate


def test_scoring_a_spent_row_as_holdout_is_refused():
    """The whole point: a rerun must not manufacture a clean final metric."""
    p = Protocol(version="v1", train_end="2023-12-03", validation_end="2025-02-26",
                 feature_version="v2", seeds={}, class_orders={})
    m = manifest([{"match_id": 7, "used_for": [EVALUATION]}])

    with pytest.raises(PartitionError) as exc:
        require_clean_holdout([7], protocol=p, manifest=m)

    assert "7" in str(exc.value)
    assert "exploratory" in str(exc.value).lower()


def test_scoring_a_training_row_as_holdout_is_refused():
    p = Protocol(version="v1", train_end="2023-12-03", validation_end="2025-02-26",
                 feature_version="v2", seeds={}, class_orders={})
    m = manifest([{"match_id": 11, "used_for": [TRAINING]}])

    with pytest.raises(PartitionError):
        require_clean_holdout([11], protocol=p, manifest=m)


def test_rows_before_the_holdout_boundary_are_refused_even_if_unspent():
    """An unspent row is still not holdout evidence if it precedes the cut."""
    p = Protocol(version="v1", train_end="2023-12-03", validation_end="2025-02-26",
                 feature_version="v2", seeds={}, class_orders={})
    m = manifest([])

    with pytest.raises(PartitionError):
        require_clean_holdout(
            [{"match_id": 3, "kickoff_at": "2024-01-01"}], protocol=p, manifest=m
        )


def test_a_genuinely_clean_post_cut_row_is_allowed():
    p = Protocol(version="v1", train_end="2023-12-03", validation_end="2025-02-26",
                 feature_version="v2", seeds={}, class_orders={})
    m = manifest([])

    result = require_clean_holdout(
        [{"match_id": 99, "kickoff_at": "2025-09-01"}], protocol=p, manifest=m
    )

    assert result.allowed
    assert result.match_ids == [99]


def test_the_gate_reports_every_offending_row_not_just_the_first():
    p = Protocol(version="v1", train_end="2023-12-03", validation_end="2025-02-26",
                 feature_version="v2", seeds={}, class_orders={})
    m = manifest([{"match_id": 5, "used_for": [EVALUATION]}])

    with pytest.raises(PartitionError) as exc:
        require_clean_holdout(
            [{"match_id": 5, "kickoff_at": "2025-09-01"},
             {"match_id": 6, "kickoff_at": "2025-09-02"}],
            protocol=p, manifest=m,
        )

    assert "5" in str(exc.value)


def test_calibration_fit_and_assessment_partitions_cannot_be_the_same_rows():
    from app.eval_protocol import CALIBRATION_ASSESSMENT, CALIBRATION_FIT

    m = manifest([
        {"match_id": 21, "used_for": [CALIBRATION_FIT]},
        {"match_id": 22, "used_for": [CALIBRATION_FIT, CALIBRATION_ASSESSMENT]},
    ])

    with pytest.raises(PartitionError) as exc:
        m.assert_calibration_disjoint()

    assert "22" in str(exc.value)


def test_disjoint_calibration_partitions_are_accepted():
    from app.eval_protocol import CALIBRATION_ASSESSMENT, CALIBRATION_FIT

    m = manifest([
        {"match_id": 21, "used_for": [CALIBRATION_FIT]},
        {"match_id": 22, "used_for": [CALIBRATION_ASSESSMENT]},
    ])

    m.assert_calibration_disjoint()  # must not raise


# --------------------------------------------------------------------------- persistence


def test_a_manifest_round_trips_through_json_without_losing_identity():
    m = manifest([
        {"match_id": 31, "kickoff_at": "2024-05-01", "used_for": [TRAINING]},
    ])

    restored = SpentManifest.from_json(m.to_json())

    assert restored.is_spent(31)
    assert restored.entries[0]["kickoff_at"] == "2024-05-01"


def test_a_manifest_file_can_be_loaded_and_queried(tmp_path):
    path = tmp_path / "spent.json"
    path.write_text(json.dumps({"entries": [{"match_id": 41, "used_for": [EVALUATION]}]}))

    loaded = SpentManifest.load(path)

    assert loaded.is_spent(41)


def test_a_missing_manifest_file_is_an_error_not_an_empty_manifest(tmp_path):
    """An absent manifest must not silently mean 'nothing is spent'."""
    with pytest.raises(PartitionError):
        SpentManifest.load(tmp_path / "does-not-exist.json")
