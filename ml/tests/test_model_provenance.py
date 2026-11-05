"""Model provenance: the response must identify the generation that produced it.

THE REQUIREMENT
---------------
Rails stores a prediction against `model_freeze_digest`. If the ML service returns a
constant, that field records "we wrote a string", not "this artifact produced this
probability". These tests therefore pin three things:

1. the digest is COMPUTED from the artifact actually loaded;
2. a digest is only claimed when it can be verified against the freeze record;
3. when verification is impossible, the field is explicitly absent rather than wrong.

Synthetic artifacts are used throughout. Nothing here touches published models.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.model_provenance import (
    PROVENANCE_UNAVAILABLE,
    ArtifactProvenance,
    digest_for_artifact,
    load_freeze,
)


def write_artifact(directory: Path, name: str, payload: bytes = b"model-weights") -> Path:
    path = directory / name
    path.write_bytes(payload)
    return path


def write_freeze(directory: Path, artifacts: dict[str, str], protocol: str = "abc") -> Path:
    """Freeze record in the same shape as evaluation/model_freeze_v2.1.json."""
    payload = {
        "schema_version": 1,
        "frozen_at": "2026-11-03T00:00:00+00:00",
        "protocol_version": "v2.1",
        "protocol_digest": protocol,
        "artifacts": {
            name: {"sha256": sha, "bytes": 13, "feature_version": "v2"}
            for name, sha in artifacts.items()
        },
    }
    path = directory / "freeze.json"
    path.write_text(json.dumps(payload))
    return path


# --------------------------------------------------------------------------- digest

import hashlib


def sha(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def test_the_digest_is_computed_from_the_artifact_bytes(tmp_path):
    path = write_artifact(tmp_path, "model_1x2.joblib", b"weights-1")

    assert digest_for_artifact(path) == sha(b"weights-1")


def test_a_different_artifact_yields_a_different_digest(tmp_path):
    a = write_artifact(tmp_path, "a.joblib", b"weights-a")
    b = write_artifact(tmp_path, "b.joblib", b"weights-b")

    assert digest_for_artifact(a) != digest_for_artifact(b)


def test_the_digest_changes_when_the_file_changes(tmp_path):
    path = write_artifact(tmp_path, "model.joblib", b"original")
    before = digest_for_artifact(path)
    path.write_bytes(b"replaced")

    assert digest_for_artifact(path) != before


# --------------------------------------------------------------------------- verification


def test_a_matching_artifact_is_reported_as_verified(tmp_path):
    path = write_artifact(tmp_path, "model_1x2.joblib", b"weights")
    freeze_path = write_freeze(tmp_path, {"model_1x2.joblib": sha(b"weights")})

    freeze = load_freeze(freeze_path)
    provenance = ArtifactProvenance.for_artifact(path, freeze=freeze)

    assert provenance.verified is True
    assert provenance.digest == sha(b"weights")
    assert provenance.freeze_digest == "abc"


def test_a_checksum_mismatch_is_not_claimed_as_the_frozen_generation(tmp_path):
    """The central safety property: a modified artifact must not borrow the freeze's
    authority."""
    path = write_artifact(tmp_path, "model_1x2.joblib", b"real-weights")
    freeze_path = write_freeze(tmp_path, {"model_1x2.joblib": sha(b"something-else")})

    freeze = load_freeze(freeze_path)
    provenance = ArtifactProvenance.for_artifact(path, freeze=freeze)

    assert provenance.verified is False
    # The actual digest is still reported, so the caller can see what ran.
    assert provenance.digest == sha(b"real-weights")
    # But it must NOT be presented as the frozen generation.
    assert provenance.freeze_digest is None
    assert provenance.reason == "checksum_mismatch"


def test_an_artifact_absent_from_the_freeze_is_unverified(tmp_path):
    path = write_artifact(tmp_path, "other.joblib", b"weights")
    freeze_path = write_freeze(tmp_path, {"model_1x2.joblib": sha(b"weights")})

    provenance = ArtifactProvenance.for_artifact(path, freeze=load_freeze(freeze_path))

    assert provenance.verified is False
    assert provenance.reason == "not_in_freeze"


def test_without_a_freeze_record_nothing_is_claimed(tmp_path):
    path = write_artifact(tmp_path, "model_1x2.joblib", b"weights")

    provenance = ArtifactProvenance.for_artifact(path, freeze=None)

    assert provenance.verified is False
    assert provenance.freeze_digest is None
    assert provenance.reason == "no_freeze_record"
    # The computed digest is still available for logging.
    assert provenance.digest == sha(b"weights")


def test_a_missing_artifact_file_is_reported_not_guessed(tmp_path):
    provenance = ArtifactProvenance.for_artifact(tmp_path / "absent.joblib", freeze=None)

    assert provenance.verified is False
    assert provenance.digest is None
    assert provenance.reason == "artifact_missing"


def test_the_unavailable_sentinel_is_a_stable_documented_value():
    # Callers key on this; changing it silently would break the contract.
    assert PROVENANCE_UNAVAILABLE == "unavailable"


# --------------------------------------------------------------------------- response shape


def test_provenance_serialises_to_the_response_fields(tmp_path):
    path = write_artifact(tmp_path, "model_1x2.joblib", b"weights")
    provenance = ArtifactProvenance.for_artifact(
        path, freeze=load_freeze(write_freeze(tmp_path, {"model_1x2.joblib": sha(b"weights")}))
    )

    payload = provenance.to_response_fields()

    assert payload["model_freeze_digest"] == sha(b"weights")
    assert payload["provenance_status"] == "verified"
    # `feature_version` is NOT part of the response fields: the endpoint supplies
    # it, and duplicating it there caused a duplicate-keyword TypeError.
    assert "feature_version" not in payload


def test_an_unverified_artifact_reports_an_explicit_status(tmp_path):
    path = write_artifact(tmp_path, "model_1x2.joblib", b"weights")
    provenance = ArtifactProvenance.for_artifact(
        path, freeze=load_freeze(write_freeze(tmp_path, {"model_1x2.joblib": sha(b"tampered")}))
    )

    payload = provenance.to_response_fields()

    # No digest is offered, but the status says WHY, rather than omitting the field
    # and leaving the caller to guess between "old service" and "tampered artifact".
    assert payload["model_freeze_digest"] is None
    assert payload["provenance_status"] == "checksum_mismatch"
