"""The prediction response carries provenance for the model that answered.

These tests exercise the real FastAPI app with a synthetic artifacts directory and a
synthetic freeze record, so the digest is proven to travel through the response rather
than being asserted on the helper alone.

No published artifact is touched: `MODEL_ARTIFACTS_DIR` and `MODEL_FREEZE_PATH` point
at pytest's tmp directory.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient


def sha(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


@pytest.fixture()
def provenance_env(tmp_path, monkeypatch):
    """A temp artifacts dir plus a freeze record matching one artifact."""
    artifacts = tmp_path / "artifacts"
    artifacts.mkdir()

    # The response path derives the file name from market/source; create the ones
    # the tests need and record their checksums.
    recorded: dict[str, dict] = {}
    for name in ("model_1x2.joblib", "model_btts.joblib", "model_goal_distribution.joblib"):
        payload = f"weights-{name}".encode()
        (artifacts / name).write_bytes(payload)
        recorded[name] = {"sha256": sha(payload), "bytes": len(payload), "feature_version": "v2"}

    freeze = {
        "schema_version": 1,
        "protocol_version": "v2.1",
        "protocol_digest": "protocol-digest-xyz",
        "artifacts": recorded,
    }
    freeze_path = artifacts / "freeze.json"
    freeze_path.write_text(json.dumps(freeze))

    monkeypatch.setenv("MODEL_ARTIFACTS_DIR", str(artifacts))
    monkeypatch.setenv("MODEL_FREEZE_PATH", str(freeze_path))

    # No module reload: `_provenance_for` resolves the environment per call, so
    # patching the environment is enough and no other test inherits a stale module.
    import ml.app.main as main_module

    yield main_module, artifacts, freeze


def test_the_helper_reports_a_verified_digest(provenance_env):
    main_module, _artifacts, freeze = provenance_env

    fields = main_module._provenance_for("1x2", "classifier")

    assert fields["provenance_status"] == "verified"
    # `model_freeze_digest` is the ARTIFACT's SHA-256, not the protocol digest: it
    # must identify the exact file that produced the probabilities. The protocol
    # digest identifies the evaluation rules, which is a different claim.
    expected = freeze["artifacts"]["model_1x2.joblib"]["sha256"]
    assert fields["model_freeze_digest"] == expected
    assert fields["artifact_sha256"] == expected


def test_the_helper_refuses_a_tampered_artifact(provenance_env):
    main_module, artifacts, _freeze = provenance_env
    (artifacts / "model_1x2.joblib").write_bytes(b"swapped-after-freeze")

    fields = main_module._provenance_for("1x2", "classifier")

    assert fields["provenance_status"] == "checksum_mismatch"
    assert fields["model_freeze_digest"] is None
    # The computed digest is still visible, so an operator can see WHAT ran.
    assert fields["artifact_sha256"] == sha(b"swapped-after-freeze")


def test_the_helper_reports_missing_when_no_artifact_exists(provenance_env):
    main_module, _artifacts, _freeze = provenance_env

    fields = main_module._provenance_for("over_under_2.5", "classifier")

    assert fields["provenance_status"] == "artifact_missing"
    assert fields["model_freeze_digest"] is None


def test_a_missing_freeze_record_yields_no_digest(tmp_path, monkeypatch):
    artifacts = tmp_path / "artifacts"
    artifacts.mkdir()
    (artifacts / "model_1x2.joblib").write_bytes(b"weights")

    monkeypatch.setenv("MODEL_ARTIFACTS_DIR", str(artifacts))
    monkeypatch.setenv("MODEL_FREEZE_PATH", str(artifacts / "absent.json"))

    # `provenance_env` is not used here on purpose (it would create a freeze), but
    # the module still has to be imported the same way. `import_module` avoids
    # depending on another test having imported it first.
    from importlib import import_module

    main_module = import_module("ml.app.main")

    fields = main_module._provenance_for("1x2", "classifier")

    assert fields["provenance_status"] == "no_freeze_record"
    assert fields["model_freeze_digest"] is None


def test_the_response_schema_keeps_existing_fields_and_adds_optional_provenance(provenance_env):
    """Backward compatibility: nothing previously returned may disappear."""
    main_module, _artifacts, _freeze = provenance_env

    fields = set(main_module.PredictResponse.model_fields)

    for required in ("market", "probabilities", "model_version", "predicted_at",
                     "feature_version"):
        assert required in fields

    for added in ("model_freeze_digest", "artifact_sha256", "provenance_status"):
        assert added in fields
        # Additive only: every new field has a default, so an old client is unaffected.
        assert main_module.PredictResponse.model_fields[added].is_required() is False


def test_correct_score_provenance_resolves_to_the_goal_model_artifact(provenance_env):
    main_module, artifacts, freeze = provenance_env

    fields = main_module._provenance_for("correct_score", "goal_model")

    assert fields["provenance_status"] == "verified"
    assert fields["artifact_sha256"] == freeze["artifacts"]["model_goal_distribution.joblib"]["sha256"]


def test_the_digest_is_not_a_constant_across_different_artifacts(provenance_env):
    """Two verified artifacts must not produce the same digest.

    This is what separates a real computation from a hardcoded string: a constant
    would make every market's provenance identical.
    """
    main_module, _artifacts, _freeze = provenance_env

    first = main_module._provenance_for("1x2", "classifier")
    second = main_module._provenance_for("btts", "classifier")

    assert first["artifact_sha256"] != second["artifact_sha256"]
