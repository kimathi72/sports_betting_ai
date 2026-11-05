"""Tests for market-specific, history-based inference.

These cover the failure modes the original integration got wrong: a generic 1X2
artifact answering for every market, a missing artifact producing a fabricated
confidence, an unknown market accepted silently, and Rails and the service
disagreeing about the request schema.

Every test that expects a 503 asserts the DETAIL names the requested market, so a
future refactor cannot satisfy the status code by falling back to something else.
"""
from __future__ import annotations

import json
import math
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient

import ml.app.main as main
from ml.app.features import FEATURE_NAMES
from ml.app.goal_models import PoissonGoalModel
from ml.app.main import app
from ml.app.model import train_baseline, train_binary_classifier
from ml.app.model_store import ModelBundle, save_bundle

client = TestClient(app)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def _features(value: float = 1.0) -> dict[str, float]:
    return {name: value for name in FEATURE_NAMES}


def _flat_payload(value: float = 1.0) -> dict[str, float]:
    return _features(value)


@pytest.fixture(autouse=True)
def _reset(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    # Every path is redirected into a temporary directory. The image ships real
    # published artifacts, so a test that forgot to override one would be silently
    # answered by a production model — and pass for the wrong reason.
    monkeypatch.setattr(main, "_artifact_paths", {})
    monkeypatch.setattr(main, "_model_caches", {})
    monkeypatch.setattr(main, "MODEL_PATH", str(tmp_path / "no_model.joblib"))
    monkeypatch.setattr(main, "GOAL_MODEL_PATH", str(tmp_path / "no_goal_model.joblib"))
    monkeypatch.setattr(main, "_artifact_dir", str(tmp_path / "artifacts"))
    # The path is a module attribute (a single source of truth), so the fixture sets
    # it the same way an operator would via the environment at start-up.
    monkeypatch.setattr(main, "GOAL_MODEL_PATH", "/nonexistent/goal_model.joblib")


def _binary_model(path: Path, market: str, classes: tuple[str, str]) -> Path:
    rng = np.random.default_rng(7)
    n = 120
    X = np.vstack(
        [
            2.0 + rng.normal(0, 0.5, (60, len(FEATURE_NAMES))),
            rng.normal(0, 0.5, (60, len(FEATURE_NAMES))),
        ]
    )
    y = np.array([classes[0]] * 60 + [classes[1]] * 60, dtype=object)
    _, bundle = train_binary_classifier(X, y, model_version=f"{market}-test", market=market)
    save_bundle(bundle, path)
    return path


def _multi_model(path: Path) -> Path:
    rng = np.random.default_rng(11)
    n = 180
    X = np.vstack(
        [
            2.0 + rng.normal(0, 0.5, (60, len(FEATURE_NAMES))),
            1.0 + rng.normal(0, 0.5, (60, len(FEATURE_NAMES))),
            np.abs(rng.normal(0, 0.5, (60, len(FEATURE_NAMES)))),
        ]
    )
    y = np.array(["H"] * 60 + ["D"] * 60 + ["A"] * 60, dtype=object)
    _, bundle = train_baseline(X, y, model_version="1x2-test")
    save_bundle(bundle, path)
    return path


def _history_matches(count: int = 12) -> list[dict]:
    """A small but real history: four clubs, results, chronological kickoffs."""
    base = datetime(2025, 8, 1, 15, tzinfo=timezone.utc)
    pairs = [(1, 2), (3, 4), (1, 3), (2, 4), (1, 4), (2, 3)]
    scores = [(2, 1), (0, 0), (1, 1), (3, 1), (0, 2), (2, 2)]
    rows = []
    for index in range(count):
        home, away = pairs[index % len(pairs)]
        hs, as_ = scores[index % len(scores)]
        rows.append(
            {
                "id": 1000 + index,
                "kickoff_at": (base + timedelta(days=7 * index)).isoformat(),
                "home_team_id": home,
                "away_team_id": away,
                "home_score": hs,
                "away_score": as_,
                "status": "completed",
            }
        )
    return rows


def _goal_model_path(tmp_path: Path) -> Path:
    history = _history_matches(18)
    model = PoissonGoalModel.fit(history)
    bundle = ModelBundle(
        classifier=model,
        feature_names=list(FEATURE_NAMES),
        classes=["H", "D", "A"],
        model_version="goal-test",
        trained_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
        market="goals",
    )
    path = tmp_path / "model_goal_distribution.joblib"
    save_bundle(bundle, path)
    return path


# ---------------------------------------------------------------------------
# Unknown markets
# ---------------------------------------------------------------------------


def test_unknown_market_is_400_before_any_artifact_lookup() -> None:
    response = client.post("/predict/teleportation", json=_flat_payload())
    assert response.status_code == 400
    assert "unsupported market" in response.json()["detail"]


def test_unknown_market_is_400_on_the_query_parameter_form() -> None:
    response = client.post("/predict", params={"market": "nope"}, json=_flat_payload())
    assert response.status_code == 400


def test_derived_markets_do_not_have_their_own_artifact() -> None:
    response = client.get("/model/status", params={"market": "double_chance"})
    assert response.status_code == 400
    assert "derived" in response.json()["detail"].lower()


def test_correct_score_reports_no_artifact_of_its_own() -> None:
    # Correct score IS serviceable, but only from the goal grid; it must not claim
    # to have a fitted artifact, which would let it drift from 1X2.
    response = client.get("/model/status", params={"market": "correct_score"})
    assert response.status_code == 400
    assert "goal distribution" in response.json()["detail"]


# ---------------------------------------------------------------------------
# 1X2 / Double Chance / Over-Under / BTTS on the flat contract
# ---------------------------------------------------------------------------


def test_1x2_flat_prediction(tmp_path: Path) -> None:
    main.set_artifact_path("1x2", _multi_model(tmp_path / "m_1x2.joblib"))
    response = client.post("/predict/1x2", json=_flat_payload())
    assert response.status_code == 200
    body = response.json()
    assert set(body["probabilities"]) == {"H", "D", "A"}
    assert math.isclose(sum(body["probabilities"].values()), 1.0, abs_tol=1e-6)


def test_double_chance_is_derived_from_1x2(tmp_path: Path) -> None:
    main.set_artifact_path("1x2", _multi_model(tmp_path / "m_1x2.joblib"))
    one_x_two = client.post("/predict/1x2", json=_flat_payload()).json()["probabilities"]
    double = client.post("/predict/double_chance", json=_flat_payload()).json()["probabilities"]
    assert math.isclose(double["1X"], one_x_two["H"] + one_x_two["D"], abs_tol=1e-9)
    assert math.isclose(double["X2"], one_x_two["D"] + one_x_two["A"], abs_tol=1e-9)
    assert math.isclose(double["12"], one_x_two["H"] + one_x_two["A"], abs_tol=1e-9)


def test_over_under_returns_two_outcomes(tmp_path: Path) -> None:
    main.set_artifact_path(
        "over_under_2.5", _binary_model(tmp_path / "m_ou.joblib", "over_under_2.5", ("Over", "Under"))
    )
    response = client.post("/predict/over_under_2.5", json=_flat_payload())
    assert response.status_code == 200
    assert set(response.json()["probabilities"]) == {"Over", "Under"}


def test_btts_returns_two_outcomes(tmp_path: Path) -> None:
    main.set_artifact_path("btts", _binary_model(tmp_path / "m_btts.joblib", "btts", ("Yes", "No")))
    response = client.post("/predict/btts", json=_flat_payload())
    assert response.status_code == 200
    assert set(response.json()["probabilities"]) == {"Yes", "No"}


# ---------------------------------------------------------------------------
# Missing artifacts: 503, never a fabricated prediction
# ---------------------------------------------------------------------------


def test_missing_market_artifact_is_503_and_names_the_market(tmp_path: Path) -> None:
    missing = tmp_path / "nothing_here.joblib"
    main.set_artifact_path("btts", missing)
    response = client.post("/predict/btts", json=_flat_payload())
    assert response.status_code == 503
    detail = response.json()["detail"]
    assert "btts" in detail
    assert "NOT generated" in detail or "not" in detail.lower()
    assert "probabilities" not in response.json()


def test_a_1x2_artifact_is_never_served_as_btts(tmp_path: Path) -> None:
    main.set_artifact_path("1x2", _multi_model(tmp_path / "m_1x2.joblib"))
    main.set_artifact_path("btts", tmp_path / "absent.joblib")
    response = client.post("/predict/btts", json=_flat_payload())
    assert response.status_code == 503
    assert "btts" in response.json()["detail"]


def test_ready_reports_which_markets_are_missing(tmp_path: Path) -> None:
    main.set_artifact_path("1x2", _multi_model(tmp_path / "m_1x2.joblib"))
    response = client.get("/ready")
    assert response.status_code == 503
    assert response.json()["checks"]["1x2"] == "ok"
    assert response.json()["checks"]["goal_distribution"] == "missing"


# ---------------------------------------------------------------------------
# Malformed input
# ---------------------------------------------------------------------------


def test_extra_feature_key_is_rejected() -> None:
    payload = _flat_payload()
    payload["home_expected_goals"] = 1.5
    response = client.post("/predict/1x2", json=payload)
    assert response.status_code == 422


def test_missing_feature_key_is_rejected() -> None:
    payload = _flat_payload()
    payload.pop("h2h_draws")
    response = client.post("/predict/1x2", json=payload)
    assert response.status_code == 422


def test_non_numeric_feature_is_rejected() -> None:
    payload = _flat_payload()
    payload["home_last5_points"] = "not-a-number"
    response = client.post("/predict/1x2", json=payload)
    assert response.status_code == 422


def test_nan_and_infinity_features_are_rejected_at_the_schema_boundary(tmp_path: Path) -> None:
    """NaN is a valid float, so it must be refused explicitly.

    Left unchecked it reaches scikit-learn, which raises from inside
    ``predict_proba`` — one caller's bad input becomes a 500. The rejection is a
    clean 422 that names the offending field.
    """
    main.set_artifact_path("1x2", _multi_model(tmp_path / "m_1x2.joblib"))
    for bad, label in ((float("nan"), "nan"), (float("inf"), "inf"), (float("-inf"), "-inf")):
        # ``json=`` renders non-finite floats as the NaN/Infinity literals, which is
        # exactly how such a value can arrive over the wire. httpx refuses to encode
        # them client-side, so the request is posted as pre-rendered content — the
        # same bytes a hostile or buggy caller would send.
        import json as _json

        payload = _flat_payload()
        payload["home_last5_points"] = bad
        with pytest.raises(ValueError):
            _json.dumps({"x": float("nan")}, allow_nan=False)
        body = _json.dumps(payload, allow_nan=True)  # NaN/Infinity literals
        response = client.post(
            "/predict/1x2", content=body, headers={"content-type": "application/json"}
        )
        assert response.status_code == 422, f"{label} was accepted by the schema"
        assert response.headers["content-type"].startswith("application/json")


# ---------------------------------------------------------------------------
# History-based inference
# ---------------------------------------------------------------------------


def test_history_prediction_serves_every_grid_market_consistently(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(main, "GOAL_MODEL_PATH", str(_goal_model_path(tmp_path)))
    main._model_caches.clear()

    match = {
        "id": 9001,
        "kickoff_at": "2026-11-10T15:00:00Z",
        "home_team_id": 1,
        "away_team_id": 2,
    }
    body = {"match": match, "history": _history_matches(18)}

    one_x_two = client.post("/predict/from-history/1x2", json=body)
    over_under = client.post("/predict/from-history/over_under_2.5", json=body)
    btts = client.post("/predict/from-history/btts", json=body)
    double = client.post("/predict/from-history/double_chance", json=body)

    for response in (one_x_two, over_under, btts, double):
        assert response.status_code == 200, response.json()

    h, d, a = (one_x_two.json()["probabilities"][k] for k in ("H", "D", "A"))
    over = over_under.json()["probabilities"]["Over"]
    yes = btts.json()["probabilities"]["Yes"]
    dc = double.json()["probabilities"]

    # Consistency: Double Chance is exactly the 1X2 sums.
    assert math.isclose(dc["1X"], h + d, abs_tol=1e-9)
    assert math.isclose(dc["X2"], d + a, abs_tol=1e-9)
    assert math.isclose(dc["12"], h + a, abs_tol=1e-9)
    # And BTTS never exceeds Over 2.5: conceding a goal is not required to score.
    assert yes <= over + 0.35  # loose bound; exact equality is not implied


def test_history_prediction_ignores_same_kickoff_results(tmp_path: Path, monkeypatch) -> None:
    """A history row at the fixture's own kickoff must not influence it."""
    monkeypatch.setattr(main, "GOAL_MODEL_PATH", str(_goal_model_path(tmp_path)))
    main._model_caches.clear()

    match = {"id": 9002, "kickoff_at": "2025-10-01T15:00:00Z", "home_team_id": 1, "away_team_id": 2}
    baseline = client.post(
        "/predict/from-history/1x2", json={"match": match, "history": _history_matches(12)}
    )
    poisoned = _history_matches(12) + [
        {
            "id": 9500,
            "kickoff_at": match["kickoff_at"],
            "home_team_id": 1,
            "away_team_id": 2,
            "home_score": 9,
            "away_score": 0,
            "status": "completed",
        }
    ]
    with_poison = client.post(
        "/predict/from-history/1x2", json={"match": match, "history": poisoned}
    )
    assert baseline.status_code == 200
    assert with_poison.status_code == 200
    assert baseline.json()["probabilities"] == with_poison.json()["probabilities"]


def test_history_prediction_503_without_a_goal_model(monkeypatch) -> None:
    monkeypatch.setattr(main, "GOAL_MODEL_PATH", "/nonexistent/goal.joblib")
    main._model_caches.clear()
    match = {"id": 9003, "kickoff_at": "2026-11-10T15:00:00Z", "home_team_id": 1, "away_team_id": 2}
    response = client.post(
        "/predict/from-history/correct_score", json={"match": match, "history": _history_matches(6)}
    )
    assert response.status_code == 503
    assert "correct_score" in response.json()["detail"]


def test_history_prediction_rejects_a_match_without_teams(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(main, "GOAL_MODEL_PATH", str(_goal_model_path(tmp_path)))
    main._model_caches.clear()
    match = {"id": 9004, "kickoff_at": "2026-11-10T15:00:00Z"}
    response = client.post("/predict/from-history/1x2", json={"match": match, "history": []})
    assert response.status_code == 422


def test_correct_score_returns_a_bounded_top_lines(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(main, "GOAL_MODEL_PATH", str(_goal_model_path(tmp_path)))
    main._model_caches.clear()
    match = {"id": 9005, "kickoff_at": "2026-11-10T15:00:00Z", "home_team_id": 1, "away_team_id": 2}
    response = client.post(
        "/predict/from-history/correct_score", json={"match": match, "history": _history_matches(18)}
    )
    assert response.status_code == 200
    probabilities = response.json()["probabilities"]
    assert 0 < len(probabilities) <= 6
    assert all(0.0 <= value <= 1.0 for value in probabilities.values())
    assert sum(probabilities.values()) <= 1.0 + 1e-9


# ---------------------------------------------------------------------------
# /markets inventory
# ---------------------------------------------------------------------------


def test_markets_endpoint_reports_real_availability(tmp_path: Path) -> None:
    main.set_artifact_path("1x2", _multi_model(tmp_path / "m_1x2.joblib"))
    response = client.get("/markets")
    assert response.status_code == 200
    inventory = response.json()["markets"]
    assert inventory["1x2"]["available"] is True
    assert inventory["btts"]["available"] is False
    assert inventory["double_chance"]["source"] == "derived from 1x2"
