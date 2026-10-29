"""Tests for the historical training pipeline.

The pipeline fetches completed matches from Rails, builds chronological
feature/target arrays, trains a baseline, and persists artifacts.
Tests use synthetic fixtures with valid chronological dates and all three
classes present in both train and validation splits.
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
import pytest
import httpx

from ml.app.training import (
    TrainingDataError,
    build_training_dataset,
    fetch_completed_matches,
    train_from_matches,
    save_artifacts,
)
from ml.app.features import FEATURE_NAMES, target_label
from ml.app.model_store import ModelBundle, load_bundle
from ml.app.metrics import evaluate_predictions


def _match(
    match_id: int,
    kickoff_at: datetime,
    home_team_id: int,
    away_team_id: int,
    home_score: int,
    away_score: int,
    status: str = "completed",
) -> dict:
    return {
        "id": match_id,
        "kickoff_at": kickoff_at,
        "home_team_id": home_team_id,
        "away_team_id": away_team_id,
        "home_score": home_score,
        "away_score": away_score,
        "status": status,
    }


def _chronological_matches(n_per_class: int = 30) -> list[dict]:
    """Generate synthetic matches with chronological dates and H/D/A outcomes.

    Uses timedelta for valid date arithmetic. Returns list ordered oldest to newest.
    Classes are interleaved so both train and validation splits contain all classes.
    """
    base = datetime(2020, 8, 1, 15, 0, tzinfo=timezone.utc)
    matches: list[dict] = []
    match_id = 1

    # Generate in rounds: each round creates one H, one D, one A
    for round_idx in range(n_per_class):
        for label_idx, label in enumerate(["H", "D", "A"]):
            kickoff = base + timedelta(days=match_id * 3)
            if label == "H":
                home_score, away_score = 2, 0
            elif label == "D":
                home_score, away_score = 1, 1
            else:
                home_score, away_score = 0, 2
            matches.append(
                _match(
                    match_id=match_id,
                    kickoff_at=kickoff,
                    home_team_id=10 + (match_id % 5),
                    away_team_id=20 + (match_id % 5),
                    home_score=home_score,
                    away_score=away_score,
                )
            )
            match_id += 1

    # Mix some scheduled/postponed matches that should be ignored as targets
    for _ in range(5):
        kickoff = base + timedelta(days=match_id * 3)
        matches.append(
            _match(
                match_id=match_id,
                kickoff_at=kickoff,
                home_team_id=30,
                away_team_id=31,
                home_score=None,
                away_score=None,
                status="scheduled",
            )
        )
        match_id += 1

    return matches


def test_build_training_dataset_chronological_and_leak_free() -> None:
    matches = _chronological_matches(n_per_class=30)
    X, y = build_training_dataset(matches)

    # 90 completed matches, 30 per class
    assert X.shape == (90, 17)
    assert y.shape == (90,)
    assert set(y) == {"H", "D", "A"}

    # First match should have zero features (no prior history)
    assert X[0, 0] == 0.0  # home_last5_points
    assert X[0, 7] == 0.0  # away_last5_points

    # Later matches should have non-zero features
    assert X[-1, 0] > 0.0 or X[-1, 7] > 0.0


def test_build_training_dataset_excludes_non_completed() -> None:
    matches = _chronological_matches(n_per_class=20)
    X, y = build_training_dataset(matches)
    # Only 60 completed matches (20 per class), scheduled excluded
    assert X.shape == (60, 17)


def test_train_from_matches_succeeds_with_enough_data() -> None:
    matches = _chronological_matches(n_per_class=40)  # 120 completed
    clf, bundle, metrics = train_from_matches(matches, model_version="test-1.0")

    assert clf is not None
    assert bundle.model_version == "test-1.0"
    assert bundle.classes == ["H", "D", "A"]
    assert set(metrics.keys()) == {"accuracy", "log_loss", "brier_score"}
    # All metrics finite
    for v in metrics.values():
        assert np.isfinite(v)


def test_train_from_matches_rejects_insufficient_data() -> None:
    matches = _chronological_matches(n_per_class=5)  # 15 completed < 30
    with pytest.raises(TrainingDataError, match="insufficient training samples"):
        train_from_matches(matches)


def test_train_from_matches_all_classes_in_both_splits() -> None:
    # 30 per class = 90 total, 80/20 split = 72/18
    # Need at least ~2 per class in validation for meaningful metrics
    matches = _chronological_matches(n_per_class=30)
    clf, bundle, metrics = train_from_matches(matches)

    # Check that the held-out validation had all three classes
    from ml.app.model import train_baseline
    X, y = build_training_dataset(matches)
    split_idx = int(X.shape[0] * 0.8)
    y_val = y[split_idx:]
    assert set(y_val) == {"H", "D", "A"}


def test_save_artifacts_roundtrip(tmp_path: Path) -> None:
    matches = _chronological_matches(n_per_class=40)
    clf, bundle, metrics = train_from_matches(matches, model_version="test-roundtrip")
    model_path = tmp_path / "model.joblib"

    save_artifacts(bundle, metrics, model_path)

    loaded = load_bundle(model_path)
    assert loaded.model_version == "test-roundtrip"
    assert loaded.classes == ["H", "D", "A"]
    assert loaded.feature_names == list(FEATURE_NAMES)

    metrics_path = tmp_path / "metrics.json"
    assert metrics_path.exists()
    raw = json.loads(metrics_path.read_text())
    assert raw["model_version"] == "test-roundtrip"
    assert set(raw.keys()) >= {"accuracy", "log_loss", "brier_score", "model_version", "feature_names", "classes"}


def test_fetch_completed_matches_requires_valid_json(monkeypatch: pytest.MonkeyPatch) -> None:
    # Mock httpx.get to return non-JSON
    class MockResponse:
        def raise_for_status(self):
            pass
        def json(self):
            raise ValueError("not json")

    def mock_get(*args, **kwargs):
        return MockResponse()

    monkeypatch.setattr(httpx, "get", mock_get)

    with pytest.raises(TrainingDataError, match="not a JSON array"):
        fetch_completed_matches("http://fake")


def test_fetch_completed_matches_requires_array(monkeypatch: pytest.MonkeyPatch) -> None:
    class MockResponse:
        def raise_for_status(self):
            pass
        def json(self):
            return {"not": "an array"}

    def mock_get(*args, **kwargs):
        return MockResponse()

    monkeypatch.setattr(httpx, "get", mock_get)

    with pytest.raises(TrainingDataError, match="not a JSON array"):
        fetch_completed_matches("http://fake")


def test_feature_names_match_model_store() -> None:
    """Ensure training uses the same feature names as model_store."""
    from ml.app.model_store import FEATURE_NAMES as STORE_FEATURES
    matches = _chronological_matches(n_per_class=10)
    X, y = build_training_dataset(matches)
    assert X.shape[1] == len(STORE_FEATURES)


def test_chronological_ordering_enforced() -> None:
    """Matches must be sorted by kickoff before being passed to compute_match_features."""
    base = datetime(2020, 8, 1, 15, 0, tzinfo=timezone.utc)
    # Deliberately out of order
    matches = [
        _match(2, base + timedelta(days=10), 10, 11, 1, 0),
        _match(1, base + timedelta(days=5), 10, 11, 2, 0),
    ]
    X, y = build_training_dataset(matches)
    assert X.shape == (2, 17)
    # The function internally sorts, so this should still work


def test_evaluate_predictions_on_real_model_outputs() -> None:
    """Verify metrics on a trained model's actual validation predictions."""
    matches = _chronological_matches(n_per_class=40)
    X, y = build_training_dataset(matches)
    split_idx = int(X.shape[0] * 0.8)

    from ml.app.model import train_baseline
    clf, _ = train_baseline(X, y)

    y_val_proba = clf.predict_proba(X[split_idx:])
    y_val_pred = clf.predict(X[split_idx:])
    metrics = evaluate_predictions(y[split_idx:], y_val_proba, y_val_pred)

    assert 0.0 <= metrics["accuracy"] <= 1.0
    assert metrics["log_loss"] > 0.0
    assert 0.0 <= metrics["brier_score"] <= 2.0  # max multiclass Brier


def test_no_leakage_same_kickoff() -> None:
    """Same-kickoff matches must not leak into each other's features."""
    base = datetime(2020, 8, 1, 15, 0, tzinfo=timezone.utc)
    # Two matches at same kickoff, second completed
    m1 = _match(1, base, 10, 11, 2, 0)
    m2 = _match(2, base, 12, 13, 1, 1)
    matches = [m1, m2]

    X, y = build_training_dataset(matches)
    # First match has no prior history
    assert X[0, 0] == 0.0
    # Second match also has no prior (m1 kickoff == m2 kickoff, not <)
    assert X[1, 0] == 0.0


def test_target_label_consistency() -> None:
    m = _match(1, datetime(2020, 8, 1, 15, 0, tzinfo=timezone.utc), 10, 11, 2, 0)
    assert target_label(m) == "H"
    m = _match(1, datetime(2020, 8, 1, 15, 0, tzinfo=timezone.utc), 10, 11, 1, 1)
    assert target_label(m) == "D"
    m = _match(1, datetime(2020, 8, 1, 15, 0, tzinfo=timezone.utc), 10, 11, 0, 2)
    assert target_label(m) == "A"

# --- Season discovery -------------------------------------------------------
#
# Season IDs were previously hardcoded (KNOWN_SEASON_IDS = [15, 8, ... 4]). That
# list silently produced an empty or wrong dataset after any re-import, because
# database IDs are not stable. Seasons must be DISCOVERED from the API.


def _seasons_response(payload, status=200):
    class MockResponse:
        def __init__(self):
            self.status_code = status
        def raise_for_status(self):
            if self.status_code >= 400:
                raise httpx.HTTPStatusError("boom", request=None, response=None)
        def json(self):
            return payload
    return MockResponse()


def test_discover_season_ids_reads_seasons_endpoint(monkeypatch) -> None:
    from ml.app.training import discover_season_ids

    seen = {}

    def mock_get(url, **kwargs):
        seen["url"] = url
        return _seasons_response([
            {"id": 4, "name": "2024/25", "match_count": 380, "completed_match_count": 380},
            {"id": 3, "name": "2023/24", "match_count": 380, "completed_match_count": 380},
        ])

    monkeypatch.setattr(httpx, "get", mock_get)

    assert discover_season_ids("http://rails") == [3, 4]
    assert "/api/v1/seasons" in seen["url"]


def test_discover_season_ids_skips_seasons_without_completed_matches(monkeypatch) -> None:
    from ml.app.training import discover_season_ids

    def mock_get(url, **kwargs):
        return _seasons_response([
            {"id": 5, "name": "2025/26", "match_count": 0, "completed_match_count": 0},
            {"id": 4, "name": "2024/25", "match_count": 380, "completed_match_count": 380},
        ])

    monkeypatch.setattr(httpx, "get", mock_get)

    assert discover_season_ids("http://rails") == [4]


def test_discover_season_ids_raises_when_no_seasons(monkeypatch) -> None:
    from ml.app.training import discover_season_ids, TrainingDataError

    monkeypatch.setattr(httpx, "get", lambda url, **kw: _seasons_response([]))

    with pytest.raises(TrainingDataError, match="no seasons"):
        discover_season_ids("http://rails")


def test_discover_season_ids_rejects_non_list(monkeypatch) -> None:
    from ml.app.training import discover_season_ids, TrainingDataError

    monkeypatch.setattr(httpx, "get", lambda url, **kw: _seasons_response({"id": 1}))

    with pytest.raises(TrainingDataError, match="not a JSON array"):
        discover_season_ids("http://rails")


def test_known_season_ids_constant_is_gone() -> None:
    import ml.app.training as training

    assert not hasattr(training, "KNOWN_SEASON_IDS"), (
        "hardcoded season ids must not return; seasons are discovered from the API"
    )
