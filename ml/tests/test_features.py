"""Tests for pre-kickoff feature engineering.

Features must only use data available before the target match's kickoff.
No target leakage: no features derived from the match being predicted
(home_score/away_score/FTR) or from future matches.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from ml.app.features import (
    FeatureError,
    compute_match_features,
    target_label,
    over_under_target,
    btts_target,
    double_chance_probabilities,
)


def _match(
    *,
    match_id: int,
    kickoff_at: datetime,
    home_team_id: int,
    away_team_id: int,
    home_score: int | None = None,
    away_score: int | None = None,
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


def test_target_label_from_completed_match() -> None:
    m = _match(match_id=1, kickoff_at=datetime(2024, 8, 17, 15, 0, tzinfo=timezone.utc), home_team_id=10, away_team_id=11, home_score=2, away_score=1)
    assert target_label(m) == "H"

    m = _match(match_id=2, kickoff_at=datetime(2024, 8, 17, 17, 30, tzinfo=timezone.utc), home_team_id=12, away_team_id=13, home_score=1, away_score=1)
    assert target_label(m) == "D"

    m = _match(match_id=3, kickoff_at=datetime(2024, 8, 18, 14, 0, tzinfo=timezone.utc), home_team_id=14, away_team_id=15, home_score=0, away_score=2)
    assert target_label(m) == "A"


def test_target_label_rejects_uncompleted_match() -> None:
    m = _match(
        match_id=4,
        kickoff_at=datetime(2024, 8, 24, 15, 0, tzinfo=timezone.utc),
        home_team_id=10,
        away_team_id=11,
        status="scheduled",
    )
    with pytest.raises(FeatureError, match="completed"):
        target_label(m)


def test_compute_features_uses_only_past_history() -> None:
    # Match 1: Liverpool 2-0 Arsenal (completed, oldest)
    m1 = _match(match_id=1, kickoff_at=datetime(2024, 8, 10, 15, 0, tzinfo=timezone.utc), home_team_id=10, away_team_id=11, home_score=2, away_score=0)
    # Match 2: Arsenal 1-1 Chelsea (completed, after m1)
    m2 = _match(match_id=2, kickoff_at=datetime(2024, 8, 11, 15, 0, tzinfo=timezone.utc), home_team_id=11, away_team_id=12, home_score=1, away_score=1)
    # Match 3: Liverpool vs Chelsea (target, after m1 and m2)
    m3 = _match(match_id=3, kickoff_at=datetime(2024, 8, 12, 15, 0, tzinfo=timezone.utc), home_team_id=10, away_team_id=12)

    history = [m1, m2]
    features = compute_match_features(m3, history)

    # Liverpool home form: 1 match played, won (3 pts)
    assert features["home_last5_points"] == 3.0
    assert features["home_last5_goals_for"] == 2.0
    assert features["home_last5_goals_against"] == 0.0
    assert features["home_last5_wins"] == 1.0
    assert features["home_last5_draws"] == 0.0
    assert features["home_last5_losses"] == 0.0
    assert features["home_matches_played"] == 1.0

    # Chelsea away form: 1 match played, drew (1 pt)
    assert features["away_last5_points"] == 1.0
    assert features["away_last5_goals_for"] == 1.0
    assert features["away_last5_goals_against"] == 1.0
    assert features["away_last5_wins"] == 0.0
    assert features["away_last5_draws"] == 1.0
    assert features["away_last5_losses"] == 0.0
    assert features["away_matches_played"] == 1.0

    # Head-to-head: Liverpool vs Chelsea have never met before
    assert features["h2h_home_wins"] == 0.0
    assert features["h2h_draws"] == 0.0
    assert features["h2h_away_wins"] == 0.0


def test_compute_features_capped_at_last5() -> None:
    home_id = 20
    away_id = 21
    kickoff = datetime(2024, 9, 1, 15, 0, tzinfo=timezone.utc)
    history = [
        _match(match_id=i, kickoff_at=kickoff - timedelta(days=d), home_team_id=home_id, away_team_id=100 + i, home_score=1, away_score=0)
        for i, d in enumerate(range(10, 0, -1))  # 10 past home matches for team 20
    ]
    target = _match(match_id=99, kickoff_at=kickoff, home_team_id=home_id, away_team_id=away_id)
    features = compute_match_features(target, history)
    # Only last 5 should count
    assert features["home_matches_played"] == 5.0
    assert features["home_last5_points"] == 15.0  # 5 wins * 3


def test_compute_features_excludes_future_matches() -> None:
    home_id = 30
    away_id = 31
    target_kickoff = datetime(2024, 8, 15, 15, 0, tzinfo=timezone.utc)
    # A match involving home_id that happens AFTER target_kickoff must not leak
    future_match = _match(
        match_id=50,
        kickoff_at=datetime(2024, 8, 20, 15, 0, tzinfo=timezone.utc),
        home_team_id=home_id,
        away_team_id=32,
        home_score=3,
        away_score=0,
    )
    target = _match(match_id=51, kickoff_at=target_kickoff, home_team_id=home_id, away_team_id=away_id)
    features = compute_match_features(target, [future_match])
    assert features["home_matches_played"] == 0.0
    assert features["home_last5_points"] == 0.0


def test_compute_features_requires_kickoff() -> None:
    m = _match(match_id=1, kickoff_at=None, home_team_id=10, away_team_id=11)
    with pytest.raises(FeatureError, match="kickoff_at"):
        compute_match_features(m, [])


def test_compute_features_requires_target_teams() -> None:
    m = _match(match_id=1, kickoff_at=datetime(2024, 8, 17, 15, 0, tzinfo=timezone.utc), home_team_id=None, away_team_id=11)
    with pytest.raises(FeatureError, match="home_team_id"):
        compute_match_features(m, [])

    m = _match(match_id=2, kickoff_at=datetime(2024, 8, 17, 15, 0, tzinfo=timezone.utc), home_team_id=10, away_team_id=None)
    with pytest.raises(FeatureError, match="away_team_id"):
        compute_match_features(m, [])


def test_compute_features_empty_history_is_valid() -> None:
    m = _match(match_id=1, kickoff_at=datetime(2024, 8, 17, 15, 0, tzinfo=timezone.utc), home_team_id=10, away_team_id=11)
    features = compute_match_features(m, [])
    assert features["home_matches_played"] == 0.0
    assert features["away_matches_played"] == 0.0
    assert features["h2h_home_wins"] == 0.0
    assert all(isinstance(v, float) for v in features.values())


def test_feature_names_stable_and_documented() -> None:
    m = _match(match_id=1, kickoff_at=datetime(2024, 8, 17, 15, 0, tzinfo=timezone.utc), home_team_id=10, away_team_id=11)
    features = compute_match_features(m, [])
    expected = {
        "home_last5_points",
        "home_last5_goals_for",
        "home_last5_goals_against",
        "home_last5_wins",
        "home_last5_draws",
        "home_last5_losses",
        "home_matches_played",
        "away_last5_points",
        "away_last5_goals_for",
        "away_last5_goals_against",
        "away_last5_wins",
        "away_last5_draws",
        "away_last5_losses",
        "away_matches_played",
        "h2h_home_wins",
        "h2h_draws",
        "h2h_away_wins",
    }
    assert set(features.keys()) == expected


# ISO 8601 timestamp handling tests for _utc()

def test_utc_iso8601_z_suffix() -> None:
    """Rails returns timestamps like '2020-08-01T15:00:00Z'."""
    from ml.app.features import _utc
    ts = "2020-08-01T15:00:00Z"
    result = _utc(ts)
    # Should be timezone-aware UTC
    assert result.tzinfo is not None


def test_utc_iso8601_offset_plus() -> None:
    """Timestamps with +hh:mm offset should be normalised to UTC."""
    from ml.app.features import _utc
    ts = "2020-08-01T15:00:00+01:00"
    result = _utc(ts)
    assert result.tzinfo is not None


def test_utc_iso8601_offset_minus() -> None:
    """Timestamps with -hh:mm offset should be normalised to UTC."""
    from ml.app.features import _utc
    ts = "2020-08-01T15:00:00-05:00"
    result = _utc(ts)
    assert result.tzinfo is not None


def test_utc_aware_python_datetime() -> None:
    """Existing Python datetime objects should still work."""
    from ml.app.features import _utc
    ts = datetime(2020, 8, 1, 15, 0, tzinfo=timezone.utc)
    result = _utc(ts)
    assert result == ts


def test_utc_naive_python_datetime() -> None:
    """Naive Python datetimes should be assumed UTC."""
    from ml.app.features import _utc
    ts = datetime(2020, 8, 1, 15, 0)
    result = _utc(ts)
    assert result.tzinfo is not None
    assert result == datetime(2020, 8, 1, 15, 0, tzinfo=timezone.utc)


def test_utc_raises_on_none() -> None:
    """None must raise FeatureError."""
    from ml.app.features import _utc
    with pytest.raises(FeatureError, match="kickoff_at"):
        _utc(None)


def test_utc_raises_on_malformed() -> None:
    """Malformed strings should raise FeatureError, not crash."""
    from ml.app.features import _utc
    with pytest.raises(FeatureError, match="kickoff_at"):
        _utc("not-a-timestamp")


def test_utc_raises_on_empty_string() -> None:
    """Empty string should raise FeatureError."""
    from ml.app.features import _utc
    with pytest.raises(FeatureError, match="kickoff_at"):
        _utc("")


# ISO 8601 string handling in compute_match_features (Rails API contract)

def test_compute_features_with_iso8601_strings() -> None:
    """History matches carry ISO 8601 string timestamps as Rails would return them."""
    # Target match
    target = _match(
        match_id=10,
        kickoff_at=datetime(2024, 8, 24, 15, 0, tzinfo=timezone.utc),
        home_team_id=10,
        away_team_id=11,
    )
    # Past match as ISO string (API-style)
    past_match = {
        "id": 1,
        "kickoff_at": "2024-08-17T15:00:00Z",
        "home_team_id": 10,
        "away_team_id": 12,
        "home_score": 2,
        "away_score": 0,
        "status": "completed",
    }
    features = compute_match_features(target, [past_match])
    assert features["home_matches_played"] == 1.0
    assert features["home_last5_points"] == 3.0


def test_compute_features_same_kickoff_no_leak_iso_string() -> None:
    """Same-kickoff match as ISO string must not leak into target features."""
    target_kickoff = datetime(2024, 8, 24, 15, 0, tzinfo=timezone.utc)
    target = _match(
        match_id=20,
        kickoff_at=target_kickoff,
        home_team_id=10,
        away_team_id=11,
    )
    # Another match at exactly the same kickoff timestamp (as ISO string)
    same_kickoff_match = {
        "id": 21,
        "kickoff_at": "2024-08-24T15:00:00Z",
        "home_team_id": 10,
        "away_team_id": 12,
        "home_score": 3,
        "away_score": 0,
        "status": "completed",
    }
    features = compute_match_features(target, [same_kickoff_match])
    assert features["home_matches_played"] == 0.0
    assert features["h2h_home_wins"] == 0.0


def test_over_under_target() -> None:
    """Test Over/Under 2.5 target function."""
    # 3-0: Over
    m = _match(match_id=1, kickoff_at=datetime(2024, 8, 1, 15, 0, tzinfo=timezone.utc), home_team_id=10, away_team_id=11, home_score=3, away_score=0)
    assert over_under_target(m) == "Over"

    # 2-1: Over
    m = _match(match_id=2, kickoff_at=datetime(2024, 8, 1, 17, 30, tzinfo=timezone.utc), home_team_id=12, away_team_id=13, home_score=2, away_score=1)
    assert over_under_target(m) == "Over"

    # 1-1: Under
    m = _match(match_id=3, kickoff_at=datetime(2024, 8, 1, 19, 0, tzinfo=timezone.utc), home_team_id=14, away_team_id=15, home_score=1, away_score=1)
    assert over_under_target(m) == "Under"

    # 0-0: Under
    m = _match(match_id=4, kickoff_at=datetime(2024, 8, 1, 20, 30, tzinfo=timezone.utc), home_team_id=16, away_team_id=17, home_score=0, away_score=0)
    assert over_under_target(m) == "Under"


def test_btts_target() -> None:
    """Test Both Teams to Score target function."""
    # 2-1: Yes
    m = _match(match_id=1, kickoff_at=datetime(2024, 8, 1, 15, 0, tzinfo=timezone.utc), home_team_id=10, away_team_id=11, home_score=2, away_score=1)
    assert btts_target(m) == "Yes"

    # 1-0: No
    m = _match(match_id=2, kickoff_at=datetime(2024, 8, 1, 17, 30, tzinfo=timezone.utc), home_team_id=12, away_team_id=13, home_score=1, away_score=0)
    assert btts_target(m) == "No"

    # 0-0: No
    m = _match(match_id=3, kickoff_at=datetime(2024, 8, 1, 19, 0, tzinfo=timezone.utc), home_team_id=14, away_team_id=15, home_score=0, away_score=0)
    assert btts_target(m) == "No"

    # 3-3: Yes
    m = _match(match_id=4, kickoff_at=datetime(2024, 8, 1, 20, 30, tzinfo=timezone.utc), home_team_id=16, away_team_id=17, home_score=3, away_score=3)
    assert btts_target(m) == "Yes"


def test_double_chance_probabilities() -> None:
    """Test Double Chance probability derivation."""
    # Perfect 1X2 distribution
    probs = {"H": 0.4, "D": 0.3, "A": 0.3}
    result = double_chance_probabilities(probs)
    assert result["1X"] == pytest.approx(0.7)
    assert result["X2"] == pytest.approx(0.6)
    assert result["12"] == pytest.approx(0.7)

    # Draw-heavy distribution
    probs = {"H": 0.2, "D": 0.6, "A": 0.2}
    result = double_chance_probabilities(probs)
    assert result["1X"] == pytest.approx(0.8)
    assert result["X2"] == pytest.approx(0.8)
    assert result["12"] == pytest.approx(0.4)

    # Home-heavy distribution
    probs = {"H": 0.7, "D": 0.2, "A": 0.1}
    result = double_chance_probabilities(probs)
    assert result["1X"] == pytest.approx(0.9)
    assert result["X2"] == pytest.approx(0.3)
    assert result["12"] == pytest.approx(0.8)


def test_target_functions_reject_incomplete() -> None:
    """Test that target functions reject incomplete matches."""
    # Incomplete match (no scores)
    m = _match(match_id=1, kickoff_at=datetime(2024, 8, 1, 15, 0, tzinfo=timezone.utc), home_team_id=10, away_team_id=11, status="completed")

    with pytest.raises(FeatureError, match="both scores"):
        over_under_target(m)

    with pytest.raises(FeatureError, match="both scores"):
        btts_target(m)


def test_target_functions_reject_uncompleted() -> None:
    """Test that target functions reject uncompleted matches."""
    m = _match(match_id=1, kickoff_at=datetime(2024, 8, 1, 15, 0, tzinfo=timezone.utc), home_team_id=10, away_team_id=11, status="scheduled")

    with pytest.raises(FeatureError, match="completed"):
        over_under_target(m)

    with pytest.raises(FeatureError, match="completed"):
        btts_target(m)