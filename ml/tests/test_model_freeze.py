"""Model-freeze record.

The freeze is the reproducibility guarantee: given a prediction, these checksums and
versions identify exactly which artifact and feature generation produced it. It must
detect drift rather than merely describe the artefacts once.
"""

from __future__ import annotations

import json
import os

import pytest

from app.model_freeze import ModelFreeze, build_freeze, sha256_of, verify_freeze


def write_artifact(directory, name, payload=b"model-bytes", meta=None):
    path = directory / name
    path.write_bytes(payload)
    if meta is not None:
        (directory / f"{name}.meta.json").write_text(json.dumps(meta))
    return path


def test_a_freeze_records_a_checksum_for_every_artifact(tmp_path):
    write_artifact(tmp_path, "model_1x2.joblib")
    write_artifact(tmp_path, "poisson_1x2.joblib", payload=b"other")

    freeze = build_freeze(tmp_path, protocol_version="v2.1", protocol_digest="abc")

    assert set(freeze.artifacts) == {"model_1x2.joblib", "poisson_1x2.joblib"}
    assert freeze.artifacts["model_1x2.joblib"]["sha256"] == sha256_of(
        tmp_path / "model_1x2.joblib"
    )


def test_a_freeze_carries_the_metadata_it_does_not_infer(tmp_path):
    write_artifact(
        tmp_path,
        "model_1x2.joblib",
        meta={
            "algorithm": "multinomial_logistic_regression",
            "feature_version": "v2",
            "feature_names": ["a", "b", "c"],
            "classes": ["H", "D", "A"],
            "trained_on": {"start": "2016-08-13", "end": "2025-02-26", "rows": 33368},
            "trained_at": "2026-11-01T12:03:32Z",
        },
    )

    freeze = build_freeze(tmp_path, protocol_version="v2.1", protocol_digest="abc")
    entry = freeze.artifacts["model_1x2.joblib"]

    assert entry["algorithm"] == "multinomial_logistic_regression"
    assert entry["feature_version"] == "v2"
    assert entry["n_features"] == 3
    assert entry["train_range"] == ["2016-08-13", "2025-02-26"]
    assert entry["rows"] == 33368


def test_a_missing_metadata_field_is_null_rather_than_guessed(tmp_path):
    write_artifact(tmp_path, "model_1x2.joblib")

    freeze = build_freeze(tmp_path, protocol_version="v2.1", protocol_digest="abc")
    entry = freeze.artifacts["model_1x2.joblib"]

    assert entry["algorithm"] is None
    assert entry["train_range"] is None
    assert entry["sha256"]  # the checksum is always real


def test_the_training_range_is_read_when_the_metadata_uses_from_and_to(tmp_path):
    # Regression: the training script writes `from`/`to`, not `start`/`end`. An
    # earlier extractor only accepted the latter and recorded null for every
    # artifact, which makes the freeze useless for reproducibility.
    write_artifact(
        tmp_path,
        "model_1x2.joblib",
        meta={
            "algorithm": "multinomial_logistic_regression",
            "feature_version": "v2",
            "trained_on": {"rows": 33370, "from": "2015-08-08", "to": "2025-02-26"},
        },
    )

    freeze = build_freeze(tmp_path, protocol_version="v2.1", protocol_digest="abc")
    entry = freeze.artifacts["model_1x2.joblib"]

    assert entry["train_range"] == ["2015-08-08", "2025-02-26"]
    assert entry["rows"] == 33370


def test_the_freeze_records_the_published_selection(tmp_path):
    write_artifact(tmp_path, "model_1x2.joblib")
    (tmp_path / "published_models.json").write_text(
        json.dumps({"1x2": {"artifact": "model_1x2.joblib"}})
    )

    freeze = build_freeze(tmp_path, protocol_version="v2.1", protocol_digest="abc")

    assert freeze.published_models["1x2"]["artifact"] == "model_1x2.joblib"


def test_the_freeze_records_runtime_versions_including_absent_libraries(tmp_path):
    write_artifact(tmp_path, "model_1x2.joblib")

    freeze = build_freeze(tmp_path, protocol_version="v2.1", protocol_digest="abc")

    assert freeze.runtime["python"]
    # Every tracked library appears, even if it could not be imported.
    assert "numpy" in freeze.runtime["libraries"]


def test_a_freeze_round_trips_through_json(tmp_path):
    write_artifact(tmp_path, "model_1x2.joblib")
    freeze = build_freeze(tmp_path, protocol_version="v2.1", protocol_digest="abc")

    restored = ModelFreeze.from_dict(json.loads(freeze.to_json()))

    assert restored.protocol_digest == "abc"
    assert restored.artifacts["model_1x2.joblib"]["sha256"] == (
        freeze.artifacts["model_1x2.joblib"]["sha256"]
    )


def test_verification_passes_when_nothing_changed(tmp_path):
    write_artifact(tmp_path, "model_1x2.joblib")
    freeze = build_freeze(tmp_path, protocol_version="v2.1", protocol_digest="abc")

    assert verify_freeze(freeze, tmp_path) == []


def test_verification_detects_an_overwritten_artifact(tmp_path):
    """The point of a checksum: a silently replaced model must be visible."""
    write_artifact(tmp_path, "model_1x2.joblib", payload=b"original")
    freeze = build_freeze(tmp_path, protocol_version="v2.1", protocol_digest="abc")

    (tmp_path / "model_1x2.joblib").write_bytes(b"replaced")

    problems = verify_freeze(freeze, tmp_path)
    assert len(problems) == 1
    assert "checksum changed" in problems[0]


def test_verification_detects_a_deleted_artifact(tmp_path):
    write_artifact(tmp_path, "model_1x2.joblib")
    freeze = build_freeze(tmp_path, protocol_version="v2.1", protocol_digest="abc")

    os.remove(tmp_path / "model_1x2.joblib")

    problems = verify_freeze(freeze, tmp_path)
    assert problems and "missing on disk" in problems[0]


def test_describe_is_human_readable_and_lists_every_artifact(tmp_path):
    write_artifact(tmp_path, "model_1x2.joblib")
    freeze = build_freeze(tmp_path, protocol_version="v2.1", protocol_digest="abc")

    text = freeze.describe()

    assert "model_1x2.joblib" in text
    assert "v2.1" in text
