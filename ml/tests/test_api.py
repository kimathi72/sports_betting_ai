"""Tests for the ML inference API endpoints.

Contract:
- GET /health -> {"status":"ok"}
- GET /ready -> {"status":"ready"} / {"status":"not_ready", ...}
- POST /predict with flat JSON feature dict -> {"probabilities": {"H": f, "D": f, "A": f}, ...}
- GET /model/status -> model version, trained_at, classes, feature names
- GET /metrics -> held-out metrics if available
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient

from ml.app.main import app
from ml.app.model_store import ModelBundle, save_bundle
from ml.app.model import train_baseline
from ml.app.features import FEATURE_NAMES


@pytest.fixture
def mock_model(tmp_path: Path) -> Path:
    rng = np.random.default_rng(42)
    n = 120
    X = np.zeros((n, len(FEATURE_NAMES)), dtype=float)
    y = np.empty(n, dtype=object)
    for label_idx, label in enumerate(["H", "D", "A"]):
        start = label_idx * 40
        end = start + 40
        y[start:end] = label
        for j in range(len(FEATURE_NAMES)):
            if label == "H":
                X[start:end, j] = 2.0 + rng.normal(0, 0.5, 40)
            elif label == "D":
                X[start:end, j] = 1.5 + rng.normal(0, 0.5, 40)
            else:
                X[start:end, j] = 1.0 + rng.normal(0, 0.5, 40)
    clf, bundle = train_baseline(X, y)

    path = tmp_path / "model.joblib"
    save_bundle(bundle, path)
    return path


def test_health_endpoint() -> None:
    client = TestClient(app)
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_ready_endpoint_no_model(monkeypatch: pytest.MonkeyPatch) -> None:
    import ml.app.main as main
    monkeypatch.setattr(main, "MODEL_PATH", "/nonexistent/model.joblib")
    # Readiness also covers the goal distribution, which correct score needs.
    monkeypatch.setattr(main, "GOAL_MODEL_PATH", "/nonexistent/goal.joblib")
    monkeypatch.setattr(main, "_model_caches", {})
    client = TestClient(app)
    resp = client.get("/ready")
    assert resp.status_code == 503
    assert resp.json()["status"] == "not_ready"


def test_ready_endpoint_with_model(mock_model: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    import ml.app.main as main
    monkeypatch.setattr(main, "MODEL_PATH", str(mock_model))
    monkeypatch.setattr(main, "_model_caches", {})
    client = TestClient(app)
    resp = client.get("/ready")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ready"


def test_predict_rejects_when_no_model(monkeypatch: pytest.MonkeyPatch) -> None:
    import ml.app.main as main
    monkeypatch.setattr(main, "MODEL_PATH", "/nonexistent/model.joblib")
    monkeypatch.setattr(main, "_model_caches", {})
    client = TestClient(app)
    payload = {name: 0.0 for name in FEATURE_NAMES}
    resp = client.post("/predict", json=payload)
    assert resp.status_code == 503
    assert "model" in resp.json()["detail"].lower()


def test_predict_accepts_valid_features(mock_model: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    import ml.app.main as main
    monkeypatch.setattr(main, "MODEL_PATH", str(mock_model))
    monkeypatch.setattr(main, "_model_caches", {})
    client = TestClient(app)
    payload = {name: 1.0 for name in FEATURE_NAMES}
    resp = client.post("/predict", json=payload)
    assert resp.status_code == 200
    data = resp.json()
    # `market` and `feature_version` were added so a caller can verify WHICH market
    # answered and which schema produced the vector; the probabilities contract is
    # unchanged.
    #
    # `model_freeze_digest`, `artifact_sha256` and `provenance_status` are the
    # provenance contract (handout §19). They are additive and always present; the
    # digest is None unless the loaded artifact matches the freeze record.
    assert set(data.keys()) == {
        "market",
        "probabilities",
        "model_version",
        "predicted_at",
        "feature_version",
        "model_freeze_digest",
        "artifact_sha256",
        "provenance_status",
    }
    # Provenance must never be asserted as a constant: in this environment the
    # artifact may not match a freeze record, so only the status vocabulary is fixed.
    assert data["provenance_status"] in {
        "verified",
        "checksum_mismatch",
        "not_in_freeze",
        "no_freeze_record",
        "artifact_missing",
        "unavailable",
    }
    assert data["market"] == "1x2"
    assert set(data["probabilities"].keys()) == {"H", "D", "A"}
    assert abs(sum(data["probabilities"].values()) - 1.0) < 1e-6


def test_predict_rejects_missing_features(mock_model: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    import ml.app.main as main
    monkeypatch.setattr(main, "MODEL_PATH", str(mock_model))
    monkeypatch.setattr(main, "_model_caches", {})
    client = TestClient(app)
    payload = {name: 1.0 for name in list(FEATURE_NAMES)[:3]}  # missing features
    resp = client.post("/predict", json=payload)
    assert resp.status_code == 422


def test_predict_rejects_extra_features(mock_model: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    import ml.app.main as main
    monkeypatch.setattr(main, "MODEL_PATH", str(mock_model))
    monkeypatch.setattr(main, "_model_caches", {})
    client = TestClient(app)
    payload = {name: 1.0 for name in FEATURE_NAMES}
    payload["extra_field"] = 1.0
    resp = client.post("/predict", json=payload)
    assert resp.status_code == 422


def test_model_status_endpoint(mock_model: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    import ml.app.main as main
    monkeypatch.setattr(main, "MODEL_PATH", str(mock_model))
    monkeypatch.setattr(main, "_model_caches", {})
    client = TestClient(app)
    resp = client.get("/model/status")
    assert resp.status_code == 200
    data = resp.json()
    assert set(data.keys()) == {"model_version", "trained_at", "classes", "feature_names", "market"}
    assert data["model_version"] == "0.1.0"
    assert data["classes"] == ["H", "D", "A"]
    assert data["feature_names"] == list(FEATURE_NAMES)


def test_model_status_when_no_model(monkeypatch: pytest.MonkeyPatch) -> None:
    import ml.app.main as main
    monkeypatch.setattr(main, "MODEL_PATH", "/nonexistent/model.joblib")
    monkeypatch.setattr(main, "_model_caches", {})
    client = TestClient(app)
    resp = client.get("/model/status")
    assert resp.status_code == 503


def test_metrics_endpoint_when_available(mock_model: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    import ml.app.main as main
    monkeypatch.setattr(main, "MODEL_PATH", str(mock_model))
    monkeypatch.setattr(main, "METRICS_PATH", str(mock_model.parent / "metrics.json"))
    monkeypatch.setattr(main, "_model_caches", {})
    metrics_data = {"accuracy": 0.55, "log_loss": 1.05, "brier_score": 0.25}
    (mock_model.parent / "metrics.json").write_text(json.dumps(metrics_data))
    client = TestClient(app)
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert resp.json() == metrics_data


def test_metrics_endpoint_when_unavailable(monkeypatch: pytest.MonkeyPatch) -> None:
    import ml.app.main as main
    monkeypatch.setattr(main, "MODEL_PATH", "/nonexistent/model.joblib")
    monkeypatch.setattr(main, "METRICS_PATH", "/nonexistent/metrics.json")
    monkeypatch.setattr(main, "_model_caches", {})
    client = TestClient(app)
    resp = client.get("/metrics")
    assert resp.status_code == 404
    assert "not available" in resp.json()["detail"].lower()


def test_predict_rejects_non_numeric_values(mock_model: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    import ml.app.main as main
    monkeypatch.setattr(main, "MODEL_PATH", str(mock_model))
    monkeypatch.setattr(main, "_model_caches", {})
    client = TestClient(app)
    payload = {name: 1.0 for name in FEATURE_NAMES}
    payload["home_last5_points"] = "not-a-number"
    resp = client.post("/predict", json=payload)
    assert resp.status_code == 422
