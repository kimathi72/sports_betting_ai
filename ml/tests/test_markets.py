"""Tests for multi-market prediction: 1X2, Over/Under 2.5, BTTS, and Double Chance.

Tests cover:
- Target label generation for each market.
- Market-to-artifact routing.
- Double Chance derivation and overlapping-event semantics.
- API market-aware prediction and validation.
- Model artifact loading per market.
- Training/holdout separation.
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient

from ml.app.features import (
    FEATURE_NAMES,
    compute_match_features,
    target_label,
    over_under_target,
    btts_target,
    double_chance_probabilities,
)
from ml.app.model import train_baseline, train_binary_classifier, predict_binary_proba
from ml.app.model_store import ModelBundle, save_bundle, load_bundle, MARKET_1X2, MARKET_OVER_UNDER, MARKET_BTTS
from ml.app.training import (
    build_training_dataset,
    build_over_under_dataset,
    build_btts_dataset,
    train_from_matches,
    train_over_under,
    train_btts,
    train_double_chance,
)
from ml.app.metrics import (
    binary_evaluate_predictions,
    binary_uniform_baseline,
    binary_frequency_baseline,
    _reorder_proba_to_canonical,
)
from ml.app.main import app
from ml.app.main import SUPPORTED_MARKETS
from ml.app.main import set_artifact_path


@pytest.fixture(autouse=True)
def _clear_artifact_paths() -> None:
    """Clear test artifact overrides and model cache before each test."""
    import ml.app.main as main

    main._artifact_paths.clear()
    main._model_caches.clear()
    yield
    main._artifact_paths.clear()
    main._model_caches.clear()


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


def _chronological_matches(
    n_per_class: int = 30,
    home_team_id: int = 10,
    away_team_id: int = 11,
    scores=None,
) -> list[dict]:
    """Generate synthetic matches with chronological dates and balanced outcomes."""
    base = datetime(2020, 8, 1, 15, 0, tzinfo=timezone.utc)
    matches: list[dict] = []
    match_id = 1

    if scores is None:
        scores = {"H": (2, 0), "D": (1, 1), "A": (0, 2)}

    for round_idx in range(n_per_class):
        for label in ["H", "D", "A"]:
            kickoff = base + timedelta(days=match_id * 3)
            hs, as_ = scores[label]
            matches.append(
                _match(
                    match_id=match_id,
                    kickoff_at=kickoff,
                    home_team_id=home_team_id + (match_id % 5),
                    away_team_id=away_team_id + (match_id % 5),
                    home_score=hs,
                    away_score=as_,
                )
            )
            match_id += 1

    return matches


# Binary match generators

def _binary_matches_over_under(n_per_class: int = 20) -> list[dict]:
    """Generate synthetic matches where Over/Under labels are derived from scores."""
    base = datetime(2024, 8, 17, 15, 0, tzinfo=timezone.utc)
    matches: list[dict] = []
    match_id = 1

    for label_idx in range(n_per_class):
        # Over matches: total goals >= 3
        if label_idx % 2 == 0:
            home_score = 2
            away_score = 1  # total = 3 → Over
        else:
            home_score = 1
            away_score = 0  # total = 1 → Under
        kickoff = base + timedelta(days=match_id * 3)
        matches.append(
            {
                "id": match_id,
                "kickoff_at": kickoff,
                "home_team_id": 10 + (match_id % 5),
                "away_team_id": 11 + (match_id % 5),
                "home_score": home_score,
                "away_score": away_score,
                "status": "completed",
            }
        )
        match_id += 1

    return matches


def _binary_matches_btts(n_per_class: int = 20) -> list[dict]:
    """Generate synthetic matches where BTTS labels are derived from scores."""
    base = datetime(2024, 8, 17, 15, 0, tzinfo=timezone.utc)
    matches: list[dict] = []
    match_id = 1

    for label_idx in range(n_per_class):
        # BTTS Yes: both teams score
        if label_idx % 2 == 0:
            home_score = 1
            away_score = 1  # Yes
        else:
            home_score = 1
            away_score = 0  # No
        kickoff = base + timedelta(days=match_id * 3)
        matches.append(
            {
                "id": match_id,
                "kickoff_at": kickoff,
                "home_team_id": 10 + (match_id % 5),
                "away_team_id": 11 + (match_id % 5),
                "home_score": home_score,
                "away_score": away_score,
                "status": "completed",
            }
        )
        match_id += 1

    return matches


# ---------------------------------------------------------------------------
# Target label tests
# ---------------------------------------------------------------------------


def test_over_under_target_over_boundary() -> None:
    """Over 2.5 when total goals >= 3."""
    base = datetime(2024, 8, 17, 15, 0, tzinfo=timezone.utc)
    # 3-0, 2-1, 1-2, 0-3 all >= 3 total
    assert over_under_target(_match(1, base, 10, 11, 3, 0)) == "Over"
    assert over_under_target(_match(2, base, 10, 11, 2, 1)) == "Over"
    assert over_under_target(_match(3, base, 10, 11, 1, 2)) == "Over"
    assert over_under_target(_match(4, base, 10, 11, 0, 3)) == "Over"


def test_over_under_target_under_boundary() -> None:
    """Under 2.5 when total goals <= 2."""
    base = datetime(2024, 8, 17, 15, 0, tzinfo=timezone.utc)
    # 0-0, 1-0, 0-1, 1-1, 2-0, 0-2 all <= 2 total
    assert over_under_target(_match(1, base, 10, 11, 0, 0)) == "Under"
    assert over_under_target(_match(2, base, 10, 11, 1, 0)) == "Under"
    assert over_under_target(_match(3, base, 10, 11, 0, 1)) == "Under"
    assert over_under_target(_match(4, base, 10, 11, 1, 1)) == "Under"
    assert over_under_target(_match(5, base, 10, 11, 2, 0)) == "Under"
    assert over_under_target(_match(6, base, 10, 11, 0, 2)) == "Under"


def test_btts_target_yes_when_both_score() -> None:
    """BTTS Yes when both teams score at least 1."""
    base = datetime(2024, 8, 17, 15, 0, tzinfo=timezone.utc)
    assert btts_target(_match(1, base, 10, 11, 1, 1)) == "Yes"
    assert btts_target(_match(2, base, 10, 11, 2, 1)) == "Yes"
    assert btts_target(_match(3, base, 10, 11, 3, 2)) == "Yes"


def test_btts_target_no_when_one_scores() -> None:
    """BTTS No when at least one team scores 0."""
    base = datetime(2024, 8, 17, 15, 0, tzinfo=timezone.utc)
    assert btts_target(_match(1, base, 10, 11, 0, 0)) == "No"
    assert btts_target(_match(2, base, 10, 11, 1, 0)) == "No"
    assert btts_target(_match(3, base, 10, 11, 0, 1)) == "No"


def test_over_under_dataset_labels_from_binary_matches() -> None:
    """Dataset should produce Over/Under labels from binary matches."""
    matches = _binary_matches_over_under(n_per_class=20)
    X, y = build_over_under_dataset(matches)
    assert X.shape[0] == 20  # 20 matches total (alternating Over/Under)
    assert set(y) == {"Over", "Under"}


def test_btts_dataset_labels_from_binary_matches() -> None:
    """Dataset should produce Yes/No labels from binary matches."""
    matches = _binary_matches_btts(n_per_class=20)
    X, y = build_btts_dataset(matches)
    assert X.shape[0] == 20  # 20 matches total (alternating Yes/No)
    assert set(y) == {"Yes", "No"}


# ---------------------------------------------------------------------------
# Binary classifier training tests
# ---------------------------------------------------------------------------


def _make_binary_X_y(
    n_per_class: int = 60,
    market: str = MARKET_OVER_UNDER,
) -> tuple[np.ndarray, np.ndarray]:
    """Generate synthetic X/y for binary classification training."""
    rng = np.random.default_rng(42)
    n = n_per_class * 2
    X = np.zeros((n, len(FEATURE_NAMES)), dtype=float)
    y = np.empty(n, dtype=object)

    if market == MARKET_OVER_UNDER:
        pos_class = "Over"
        neg_class = "Under"
        # Over class: high feature values
        X[:n_per_class, :] = 2.0 + rng.normal(0, 0.5, (n_per_class, len(FEATURE_NAMES)))
        y[:n_per_class] = pos_class
        # Under class: low feature values
        X[n_per_class:, :] = 0.0 + rng.normal(0, 0.5, (n_per_class, len(FEATURE_NAMES)))
        y[n_per_class:] = neg_class
    elif market == MARKET_BTTS:
        pos_class = "Yes"
        neg_class = "No"
        # Yes class: higher features indicate goals
        X[:n_per_class, :] = 2.0 + rng.normal(0, 0.5, (n_per_class, len(FEATURE_NAMES)))
        y[:n_per_class] = pos_class
        # No class: lower features
        X[n_per_class:, :] = 0.0 + rng.normal(0, 0.5, (n_per_class, len(FEATURE_NAMES)))
        y[n_per_class:] = neg_class

    return X, y


def test_train_binary_classifier_over_under() -> None:
    """Test training Over/Under binary classifier."""
    X, y = _make_binary_X_y(n_per_class=60, market=MARKET_OVER_UNDER)
    clf, bundle = train_binary_classifier(X, y, model_version="ou-test-1.0")

    assert clf is not None
    assert bundle.model_version == "ou-test-1.0"
    assert set(bundle.classes) == {"Over", "Under"}


def test_train_binary_classifier_btts() -> None:
    """Test training BTTS binary classifier."""
    X, y = _make_binary_X_y(n_per_class=60, market=MARKET_BTTS)
    clf, bundle = train_binary_classifier(X, y, model_version="btts-test-1.0")

    assert clf is not None
    assert bundle.model_version == "btts-test-1.0"
    assert set(bundle.classes) == {"Yes", "No"}


def test_train_over_under_from_matches() -> None:
    """Test training Over/Under from match data."""
    matches = _binary_matches_over_under(n_per_class=40)
    clf, bundle, metrics = train_over_under(matches, model_version="ou-1.0")

    assert clf is not None
    assert bundle.classes in [["Over", "Under"], ["Under", "Over"]]
    assert set(metrics.keys()) >= {"accuracy", "log_loss", "brier_score"}


def test_train_btts_from_matches() -> None:
    """Test training BTTS from match data."""
    matches = _binary_matches_btts(n_per_class=40)
    clf, bundle, metrics = train_btts(matches, model_version="btts-1.0")

    assert clf is not None
    assert bundle.classes in [["Yes", "No"], ["No", "Yes"]]
    assert set(metrics.keys()) >= {"accuracy", "log_loss", "brier_score"}


def test_binary_predict_proba_normalized() -> None:
    """Binary predict_proba returns valid probabilities."""
    X, y = _make_binary_X_y(n_per_class=100, market=MARKET_OVER_UNDER)
    clf, bundle = train_binary_classifier(X, y)

    features = {name: 1.0 for name in FEATURE_NAMES}
    probs = predict_binary_proba(clf, features, bundle)

    assert len(probs) == 2
    total = sum(probs.values())
    assert abs(total - 1.0) < 1e-6
    for v in probs.values():
        assert 0.0 <= v <= 1.0


def test_predict_binary_proba_rejects_missing_features() -> None:
    """Binary predict_proba should reject missing features."""
    X, y = _make_binary_X_y(n_per_class=60, market=MARKET_OVER_UNDER)
    clf, bundle = train_binary_classifier(X, y)

    features = {}  # missing all features
    try:
        predict_binary_proba(clf, features, bundle)
        assert False, "Should have raised ModelError"
    except Exception:
        pass  # Expected


def test_predict_binary_proba_rejects_extra_features() -> None:
    """Binary predict_proba should reject extra features."""
    X, y = _make_binary_X_y(n_per_class=60, market=MARKET_OVER_UNDER)
    clf, bundle = train_binary_classifier(X, y)

    features = {name: 1.0 for name in FEATURE_NAMES}
    features["extra"] = 1.0
    try:
        predict_binary_proba(clf, features, bundle)
        assert False, "Should have raised ModelError"
    except Exception:
        pass  # Expected


# ---------------------------------------------------------------------------
# Double Chance derivation tests
# ---------------------------------------------------------------------------


def test_double_chance_from_uniform_1x2() -> None:
    """Double Chance from uniform 1X2 should give 0.667 each."""
    probs = {"H": 1 / 3, "D": 1 / 3, "A": 1 / 3}
    result = double_chance_probabilities(probs)
    assert result["1X"] == pytest.approx(2 / 3)
    assert result["X2"] == pytest.approx(2 / 3)
    assert result["12"] == pytest.approx(2 / 3)


def test_double_chance_from_skewed_1x2() -> None:
    """Double Chance from skewed 1X2."""
    probs = {"H": 0.5, "D": 0.3, "A": 0.2}
    result = double_chance_probabilities(probs)
    assert result["1X"] == pytest.approx(0.8)  # H + D
    assert result["X2"] == pytest.approx(0.5)  # D + A
    assert result["12"] == pytest.approx(0.7)  # H + A


def test_double_chance_bounds() -> None:
    """Each Double Chance probability must be in [0, 1]."""
    # Edge: all on H
    probs = {"H": 1.0, "D": 0.0, "A": 0.0}
    result = double_chance_probabilities(probs)
    assert 0.0 <= result["1X"] <= 1.0
    assert 0.0 <= result["X2"] <= 1.0
    assert 0.0 <= result["12"] <= 1.0

    # Edge: all on D
    probs = {"H": 0.0, "D": 1.0, "A": 0.0}
    result = double_chance_probabilities(probs)
    assert 0.0 <= result["1X"] <= 1.0
    assert 0.0 <= result["X2"] <= 1.0
    assert 0.0 <= result["12"] <= 1.0


def test_double_chance_sum_is_two() -> None:
    """Double Chance probabilities sum to 2 (overlapping events)."""
    probs = {"H": 0.4, "D": 0.3, "A": 0.3}
    result = double_chance_probabilities(probs)
    total = result["1X"] + result["X2"] + result["12"]
    assert total == pytest.approx(2.0)


def test_train_double_chance_returns_1x2_bundle() -> None:
    """Double Chance training should use the 1X2 model, not a separate classifier."""
    matches = _chronological_matches(n_per_class=40)
    clf, bundle, metrics = train_double_chance(matches, model_version="dc-1.0")

    # Should return the 1X2 bundle
    assert bundle.classes == ["H", "D", "A"]
    # Should have Double Chance metrics
    assert any("1X" in k for k in metrics.keys())


# ---------------------------------------------------------------------------
# API market-aware tests
# ---------------------------------------------------------------------------


@pytest.fixture
def ou_model(tmp_path: Path) -> Path:
    """Save an Over/Under model to a temp path."""
    rng = np.random.default_rng(42)
    n = 120
    X = np.zeros((n, len(FEATURE_NAMES)), dtype=float)
    y = np.empty(n, dtype=object)
    # 60 Over (high features), 60 Under (low features)
    X[:60, :] = 2.0 + rng.normal(0, 0.5, (60, len(FEATURE_NAMES)))
    y[:60] = "Over"
    X[60:, :] = 0.0 + rng.normal(0, 0.5, (60, len(FEATURE_NAMES)))
    y[60:] = "Under"

    clf, bundle = train_binary_classifier(
        X, y, model_version="ou-test", market="over_under_2.5"
    )
    path = tmp_path / "model_over_under_2.5.joblib"
    save_bundle(bundle, path)
    return path


@pytest.fixture
def btts_model(tmp_path: Path) -> Path:
    """Save a BTTS model to a temp path."""
    rng = np.random.default_rng(42)
    n = 120
    X = np.zeros((n, len(FEATURE_NAMES)), dtype=float)
    y = np.empty(n, dtype=object)
    # 60 Yes (high features), 60 No (low features)
    X[:60, :] = 2.0 + rng.normal(0, 0.5, (60, len(FEATURE_NAMES)))
    y[:60] = "Yes"
    X[60:, :] = 0.0 + rng.normal(0, 0.5, (60, len(FEATURE_NAMES)))
    y[60:] = "No"

    clf, bundle = train_binary_classifier(
        X, y, model_version="btts-test", market="btts"
    )
    path = tmp_path / "model_btts.joblib"
    save_bundle(bundle, path)
    return path


@pytest.fixture
def dc_model(tmp_path: Path) -> Path:
    """Save a 1X2 model (Double Chance derives from 1X2)."""
    from ml.app.model import train_baseline

    rng = np.random.default_rng(42)
    n = 180
    X = np.zeros((n, len(FEATURE_NAMES)), dtype=float)
    y = np.empty(n, dtype=object)
    # 60 H, 60 D, 60 A
    X[:60, :] = 2.0 + rng.normal(0, 0.5, (60, len(FEATURE_NAMES)))
    y[:60] = "H"
    X[60:120, :] = 1.0 + rng.normal(0, 0.5, (60, len(FEATURE_NAMES)))
    y[60:120] = "D"
    X[120:, :] = 0.0 + rng.normal(0, 0.5, (60, len(FEATURE_NAMES)))
    y[120:] = "A"

    clf, bundle = train_baseline(X, y, model_version="dc-1x2-test")
    path = tmp_path / "model_1x2.joblib"
    save_bundle(bundle, path)
    return path


def test_predict_with_market_over_under(ou_model: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Test predicting Over/Under via the market parameter."""
    import ml.app.main as main

    set_artifact_path("over_under_2.5", str(ou_model))
    monkeypatch.setattr(main, "_model_caches", {})

    client = TestClient(app)
    payload = {name: 1.0 for name in FEATURE_NAMES}
    payload["market"] = "over_under_2.5"
    resp = client.post("/predict", json=payload)
    assert resp.status_code == 200, f"Expected 200 but got {resp.status_code}: {resp.json()}"
    data = resp.json()
    probs = data["probabilities"]
    total = sum(probs.values())
    assert abs(total - 1.0) < 1e-6, f"Probabilities should sum to 1.0, got {total}"
    for v in probs.values():
        assert 0.0 <= v <= 1.0, f"Probability should be in [0,1], got {v}"
    # Over/Under must return exactly two outcomes, not H/D/A
    assert set(probs.keys()) == {"Over", "Under"}, (
        f"Expected {{'Over', 'Under'}} outcomes, got {set(probs.keys())}"
    )


def test_predict_with_market_btts(btts_model: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """BTTS market must return Yes/No outcomes, not H/D/A."""
    import ml.app.main as main

    set_artifact_path("btts", str(btts_model))
    monkeypatch.setattr(main, "_model_caches", {})

    client = TestClient(app)
    payload = {name: 1.0 for name in FEATURE_NAMES}
    payload["market"] = "btts"
    resp = client.post("/predict", json=payload)
    assert resp.status_code == 200, f"Expected 200 but got {resp.status_code}: {resp.json()}"
    data = resp.json()
    probs = data["probabilities"]
    assert set(probs.keys()) == {"Yes", "No"}, (
        f"Expected {{'Yes', 'No'}} outcomes, got {set(probs.keys())}"
    )
    total = sum(probs.values())
    assert abs(total - 1.0) < 1e-6
    for v in probs.values():
        assert 0.0 <= v <= 1.0


def test_predict_with_market_1x2(dc_model: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """1X2 market must return H/D/A outcomes."""
    import ml.app.main as main

    set_artifact_path("1x2", str(dc_model))
    monkeypatch.setattr(main, "_model_caches", {})

    client = TestClient(app)
    payload = {name: 1.0 for name in FEATURE_NAMES}
    resp = client.post("/predict", json=payload)
    assert resp.status_code == 200, resp.json()
    data = resp.json()
    probs = data["probabilities"]
    assert set(probs.keys()) == {"H", "D", "A"}, (
        f"Expected {{'H', 'D', 'A'}} outcomes, got {set(probs.keys())}"
    )
    total = sum(probs.values())
    assert abs(total - 1.0) < 1e-6


def test_predict_url_market_over_under(ou_model: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Test /predict/over_under_2.5 URL endpoint returns Over/Under outcomes."""
    import ml.app.main as main

    set_artifact_path("over_under_2.5", str(ou_model))
    monkeypatch.setattr(main, "_model_caches", {})

    client = TestClient(app)
    payload = {name: 1.0 for name in FEATURE_NAMES}
    resp = client.post("/predict/over_under_2.5", json=payload)
    assert resp.status_code == 200, resp.json()
    data = resp.json()
    probs = data["probabilities"]
    assert set(probs.keys()) == {"Over", "Under"}
    assert abs(sum(probs.values()) - 1.0) < 1e-6


def test_predict_url_market_btts(btts_model: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Test /predict/btts URL endpoint returns Yes/No outcomes."""
    import ml.app.main as main

    set_artifact_path("btts", str(btts_model))
    monkeypatch.setattr(main, "_model_caches", {})

    client = TestClient(app)
    payload = {name: 1.0 for name in FEATURE_NAMES}
    resp = client.post("/predict/btts", json=payload)
    assert resp.status_code == 200, resp.json()
    data = resp.json()
    probs = data["probabilities"]
    assert set(probs.keys()) == {"Yes", "No"}
    assert abs(sum(probs.values()) - 1.0) < 1e-6


def test_predict_never_loads_wrong_market_artifact(
    ou_model: Path, dc_model: Path, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """An Over/Under request must never silently load the 1X2 artifact."""
    import ml.app.main as main

    # Deterministic isolation: point BOTH markets at explicit paths rather than
    # relying on the production Over/Under artifact being absent from disk.
    # Without the explicit override, _get_artifact_path falls back to
    # get_model_path(), finds the real artifact, and the request succeeds — which
    # is why this test passed or failed depending on the working directory.
    set_artifact_path("1x2", str(dc_model))
    # MUST NOT reuse the `ou_model` fixture's filename: that fixture writes
    # ``tmp_path/model_over_under_2.5.joblib``, so pointing the override there
    # makes the "missing" artifact exist and the request legitimately returns
    # 200. A distinct, never-written path is what makes this test deterministic.
    missing = tmp_path / "market_model_absent.joblib"
    set_artifact_path("over_under_2.5", str(missing))
    # The autouse `_clear_artifact_paths` fixture already resets `_model_caches`;
    # replacing that dict via monkeypatch was the original bug, because
    # `_load_model` populates whichever dict object it sees.
    assert not missing.exists()
    assert main._get_artifact_path("over_under_2.5") == missing
    client = TestClient(app)
    payload = {name: 1.0 for name in FEATURE_NAMES}
    payload["market"] = "over_under_2.5"
    resp = client.post("/predict", json=payload)

    # Must return 503 (model unavailable for requested market), NOT 200 with H/D/A
    assert resp.status_code == 503
    detail = resp.json().get("detail", "").lower()
    assert "over_under_2.5" in detail
    assert "model for market" in detail


def test_predict_url_unknown_market_400(monkeypatch: pytest.MonkeyPatch) -> None:
    """POST /predict/unknown_market must return 400."""
    import ml.app.main as main

    monkeypatch.setattr(main, "_model_caches", {})

    client = TestClient(app)
    payload = {name: 1.0 for name in FEATURE_NAMES}
    resp = client.post("/predict/unknown_market", json=payload)
    assert resp.status_code == 400


def test_predict_rejects_unknown_market(monkeypatch: pytest.MonkeyPatch) -> None:
    """Unknown market should return 400 (validation before model loading)."""
    import ml.app.main as main
    # Unknown market rejected before artifact loading attempt
    monkeypatch.setattr(main, "_model_caches", {})

    client = TestClient(app)
    payload = {name: 1.0 for name in FEATURE_NAMES}
    payload["market"] = "unknown_market"
    resp = client.post("/predict", json=payload)
    # Unsupported market must return 400, not 503 (model-unavailable) or 422 (feature validation)
    assert resp.status_code == 400


def test_model_status_with_market(ou_model: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Model status should return market info for the requested market."""
    import ml.app.main as main

    set_artifact_path("over_under_2.5", str(ou_model))
    monkeypatch.setattr(main, "_model_caches", {})

    client = TestClient(app)
    resp = client.get("/model/status?market=over_under_2.5")
    assert resp.status_code == 200, f"Expected 200 but got {resp.status_code}: {resp.json()}"
    data = resp.json()
    assert data["market"] == "over_under_2.5"
    assert set(data["classes"]) == {"Over", "Under"}
    assert len(data["classes"]) == 2


def test_model_status_1x2_classes(dc_model: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """1X2 model status must return H/D/A classes."""
    import ml.app.main as main

    set_artifact_path("1x2", str(dc_model))
    monkeypatch.setattr(main, "_model_caches", {})

    client = TestClient(app)
    resp = client.get("/model/status?market=1x2")
    assert resp.status_code == 200, resp.json()
    data = resp.json()
    assert data["classes"] == ["H", "D", "A"]
    assert data["market"] == "1x2"


def test_model_status_503_when_artifact_missing(monkeypatch: pytest.MonkeyPatch) -> None:
    """Model status should return 503 when artifact is missing."""
    import ml.app.main as main

    set_artifact_path("over_under_2.5", "/nonexistent/path/model.joblib")
    monkeypatch.setattr(main, "_model_caches", {})

    client = TestClient(app)
    resp = client.get("/model/status?market=over_under_2.5")
    assert resp.status_code == 503


def test_model_status_unknown_market_400(monkeypatch: pytest.MonkeyPatch) -> None:
    """Unknown market in model status should return 400."""
    import ml.app.main as main

    monkeypatch.setattr(main, "_model_caches", {})

    client = TestClient(app)
    resp = client.get("/model/status?market=unknown_market")
    assert resp.status_code == 400


def test_supported_markets_list() -> None:
    """SUPPORTED_MARKETS should include all four markets."""
    assert "1x2" in SUPPORTED_MARKETS, "1x2 should be supported"
    assert "over_under_2.5" in SUPPORTED_MARKETS, "over_under_2.5 should be supported"
    assert "btts" in SUPPORTED_MARKETS, "btts should be supported"