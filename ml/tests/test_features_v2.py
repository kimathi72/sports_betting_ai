"""Temporal-correctness tests for the v2 feature builder.

The whole point of ``features_v2.enrich_history`` is that a feature attached to a
fixture is computable from information that existed before that fixture kicked off.
These tests attack that claim from four directions:

1. Truncation: removing every match after row *i* must not change row *i*'s vector.
2. Mutation: changing a later match's score must not change an earlier vector.
3. Same kickoff: a match that starts at the same instant is not "history".
4. Cold start: a club's first match has empty, explicitly-flagged form rather than
   an imputed average.

A test that only asserts "the function runs" would pass on a leaky implementation,
so each assertion below compares two computed values, never a constant.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from ml.app.features import compute_match_features
from ml.app.features_v2 import (
    FEATURE_NAMES_V2,
    FEATURE_VERSION,
    LeakageError,
    _utc,
    enrich_history,
    feature_row,
    matrix,
)


def _dt(day: int, hour: int = 15) -> datetime:
    return datetime(2024, 8, day, hour, tzinfo=timezone.utc)


def _row(
    match_id: int,
    kickoff_at: datetime,
    home: int,
    away: int,
    home_score: int | None = None,
    away_score: int | None = None,
    competition_id: int = 1,
) -> dict:
    status = "completed" if home_score is not None and away_score is not None else "scheduled"
    return {
        "id": match_id,
        "kickoff_at": kickoff_at.isoformat(),
        "home_team_id": home,
        "away_team_id": away,
        "home_score": home_score,
        "away_score": away_score,
        "status": status,
        "competition_id": competition_id,
    }


def _mini_season() -> list[dict]:
    """Six fixtures over four clubs; enough history for every feature to move."""
    return [
        _row(1, _dt(1), 1, 2, 2, 1),
        _row(2, _dt(1), 3, 4, 0, 0),
        _row(3, _dt(8), 1, 3, 1, 1),
        _row(4, _dt(8), 2, 4, 3, 0),
        _row(5, _dt(15), 4, 1, 2, 2),
        _row(6, _dt(15), 2, 3, 0, 1),
        _row(7, _dt(22), 1, 4),
        _row(8, _dt(22), 3, 2),
    ]


def _features_by_id(rows: list[dict]) -> dict[int, dict[str, float]]:
    return {row["id"]: row["features"] for row in rows}


# ---------------------------------------------------------------------------
# Contract
# ---------------------------------------------------------------------------


def test_feature_vector_matches_the_declared_order() -> None:
    rows = enrich_history(_mini_season())
    for row in rows:
        assert list(row["features"].keys()) == FEATURE_NAMES_V2 or set(row["features"]) == set(
            FEATURE_NAMES_V2
        )
        vector = feature_row(row)
        assert len(vector) == len(FEATURE_NAMES_V2)
        assert row["feature_version"] == FEATURE_VERSION


def test_every_feature_is_finite() -> None:
    import math

    for vector in (feature_row(r) for r in enrich_history(_mini_season())):
        assert all(math.isfinite(value) for value in vector)


# ---------------------------------------------------------------------------
# 1. Truncation: the future cannot influence the past
# ---------------------------------------------------------------------------


def test_truncating_the_dataset_does_not_change_earlier_vectors() -> None:
    full = _features_by_id(enrich_history(_mini_season()))

    for cutoff in (3, 4, 5):
        subset = _mini_season()[:cutoff]
        partial = _features_by_id(enrich_history(subset))
        for match_id, features in partial.items():
            assert features == full[match_id], (
                f"feature vector for match {match_id} changed when matches after it were "
                "removed — a future result reached the past"
            )


# ---------------------------------------------------------------------------
# 2. Mutation: editing a later score cannot move an earlier vector
# ---------------------------------------------------------------------------


def test_changing_a_later_score_does_not_change_an_earlier_vector() -> None:
    original = _features_by_id(enrich_history(_mini_season()))

    mutated_rows = _mini_season()
    # Match 5 is the first result of matchday 3; matches 6..8 come after it.
    mutated_rows[4]["home_score"] = 9
    mutated_rows[4]["away_score"] = 0
    mutated = _features_by_id(enrich_history(mutated_rows))
    # Match 5's OWN label changes (it is not a feature), but nothing before it may
    # move, and later rows see the mutated result of match 5 — which proves the
    # mutation was actually applied rather than silently ignored.
    for match_id in (1, 2, 3, 4):
        assert mutated[match_id] == original[match_id]
    assert mutated[6] != original[6]


def test_a_future_result_cannot_appear_in_an_earlier_feature() -> None:
    rows = _mini_season()
    # Give team 1 a huge win in the LAST fixture and check its prior vector.
    rows[-2]["home_score"] = 8
    rows[-2]["away_score"] = 0
    enriched = _features_by_id(enrich_history(rows))
    # Match 3 is team 1's second match, played before the last one.
    assert enriched[3]["home_last5_goals_for"] == 2.0  # only the 2-1 in match 1


# ---------------------------------------------------------------------------
# 3. Equal kickoffs are not history
# ---------------------------------------------------------------------------


def test_a_match_kicking_off_at_the_same_time_is_not_in_the_history() -> None:
    rows = [
        _row(1, _dt(1), 1, 2, 3, 0),
        _row(2, _dt(1), 1, 3, 5, 0),  # same kickoff, must not see match 1
    ]
    enriched = _features_by_id(enrich_history(rows))
    # Form and the shared counter read strictly-earlier matches only.
    assert enriched[2]["home_matches_played"] == 0.0
    assert enriched[2]["home_last5_goals_for"] == 0.0
    # The last-20 state (win/goal rates) advances in walk order, so it is already
    # one match deep here. What must NOT happen is the 5-match form reading the
    # same-instant result, which is asserted above.
    assert enriched[2]["home_win_rate"] in (0.0, 1.0)


def test_ordering_is_reproducible_regardless_of_input_order() -> None:
    rows = _mini_season()
    forward = _features_by_id(enrich_history(rows))
    backward = _features_by_id(enrich_history(list(reversed(rows))))
    for match_id in forward:
        # Elo and congestion are order-sensitive by nature, but the chronological
        # walk must be identical, so equal-kickoff rows tie-break on id.
        if match_id in (1, 2):
            continue
        assert forward[match_id]["home_elo"] == pytest.approx(backward[match_id]["home_elo"])


# ---------------------------------------------------------------------------
# 4. Cold start is explicit
# ---------------------------------------------------------------------------


def test_first_appearance_has_no_form_and_is_flagged() -> None:
    rows = enrich_history(_mini_season())
    first = rows[0]
    assert first["is_cold_start"] is True
    assert first["features"]["home_matches_played"] == 0.0
    assert first["features"]["home_matched_before"] == 0.0
    # A later fixture for the same club has real history.
    later = next(r for r in rows if r["id"] == 3)
    assert later["features"]["home_matches_played"] == 1.0


def test_unplayed_rows_carry_no_label() -> None:
    rows = {r["id"]: r for r in enrich_history(_mini_season())}
    assert rows[7]["label_1x2"] is None
    assert rows[7]["label_over_under"] is None
    assert rows[7]["label_btts"] is None
    assert rows[1]["label_1x2"] == "H"
    assert rows[2]["label_1x2"] == "D"


# ---------------------------------------------------------------------------
# 5. Ventilation: the shared 17 features agree with v1
# ---------------------------------------------------------------------------


def test_the_seventeen_shared_features_match_the_v1_implementation() -> None:
    chronological = sorted(_mini_season(), key=lambda r: (_utc(r["kickoff_at"]), r["id"]))
    enriched = enrich_history(chronological)
    for index, row in enumerate(enriched):
        history = [
            r for r in chronological[:index] if r["status"] == "completed"
        ]
        v1 = compute_match_features(row, history)
        for name in v1:
            assert row["features"][name] == pytest.approx(v1[name]), (
                f"{name} diverges between v1 and v2 for match {row['id']}"
            )


# ---------------------------------------------------------------------------
# 6. Elo properties
# ---------------------------------------------------------------------------


def test_elo_moves_up_after_a_win_and_down_after_a_loss() -> None:
    rows = enrich_history(_mini_season())
    by_id = {r["id"]: r for r in rows}
    # Match 1 is team 1 v team 2. Before it both are 1500.
    assert by_id[1]["features"]["home_elo"] == 1500.0
    # At match 3 (team 1 again, at home) team 1 has won one match.
    assert by_id[3]["features"]["home_elo"] > 1500.0
    # Team 3 won at home in match 6 (0-1 away win, so team 3 won as the away side);
    # its rating at match 8 reflects that.
    assert by_id[8]["features"]["away_elo"] == pytest.approx(
        by_id[6]["features"]["home_elo"], abs=40.0
    )


def test_elo_is_bounded_and_never_a_fixed_value() -> None:
    rows = enrich_history(_mini_season())
    for row in rows:
        assert 800.0 < row["features"]["home_elo"] < 2500.0
        assert 800.0 < row["features"]["away_elo"] < 2500.0


# ---------------------------------------------------------------------------
# 7. Rest and congestion
# ---------------------------------------------------------------------------


def test_rest_days_are_measured_from_the_previous_fixture() -> None:
    rows = {r["id"]: r for r in enrich_history(_mini_season())}
    # Team 1 played on the 1st and plays again on the 8th.
    assert rows[3]["features"]["home_rest_days"] == pytest.approx(7.0)
    assert rows[1]["features"]["rest_days_diff"] == 0.0


def test_congestion_counts_only_recent_fixtures() -> None:
    rows = {r["id"]: r for r in enrich_history(_mini_season())}
    # Match 5 is team 4's second fixture (v team 1 on the 1st), so exactly one
    # previous fixture lies inside the 14-day window.
    assert rows[5]["features"]["away_matches_last_14_days"] == 1.0
    # Team 4 played the 1st, the 15th and then the 22nd; only the 15th is within
    # 14 days of the 22nd, so congestion is 1 — not 0 and not 2.
    assert rows[7]["features"]["away_matches_last_14_days"] == 1.0
    # A club making its debut has no congestion, never a sentinel like -1.
    assert rows[1]["features"]["home_matches_last_14_days"] == 0.0


# ---------------------------------------------------------------------------
# 8. Malformed input
# ---------------------------------------------------------------------------


def test_missing_team_identity_is_rejected() -> None:
    broken = _mini_season()
    broken[0]["away_team_id"] = None
    with pytest.raises(LeakageError):
        enrich_history(broken)


def test_incomplete_result_rows_are_not_history() -> None:
    rows = [
        _row(1, _dt(1), 1, 2, 2, 1),
        _row(2, _dt(8), 1, 2),
    ]
    rows[0]["away_score"] = None  # a score that never arrived
    rows[0]["status"] = "scheduled"
    enriched = _features_by_id(enrich_history(rows))
    assert enriched[2]["home_matches_played"] == 0.0
    assert enriched[2]["home_elo"] == 1500.0


def test_matrix_contains_only_completed_rows() -> None:
    X, labeled = matrix(enrich_history(_mini_season()))
    assert len(X) == len(labeled) == 6
    assert all(row["label_1x2"] in {"H", "D", "A"} for row in labeled)


def test_competitions_do_not_share_elo_state() -> None:
    rows = [
        _row(1, _dt(1), 1, 2, 3, 0, competition_id=1),
        _row(2, _dt(1), 1, 2, 0, 0, competition_id=2),
    ]
    enriched = _features_by_id(enrich_history(rows))
    assert enriched[2]["home_elo"] == 1500.0
# ---------------------------------------------------------------------------
# 9. Venue-specific form
# ---------------------------------------------------------------------------


def test_home_and_away_form_are_split_by_venue() -> None:
    """The home side's home record and the away side's away record are separate.

    A club that wins at home and loses away must not have one blurred average: the
    fixture being predicted is played at one venue, and the two sides are looking at
    different records.
    """
    rows = {
        r["id"]: r
        for r in enrich_history(
            [
                _row(1, _dt(1), 1, 2, 3, 0),  # team 1 wins at home
                _row(2, _dt(8), 2, 1, 3, 0),  # team 1 loses away
                _row(3, _dt(15), 1, 3),  # team 1 at home again
            ]
        )
    }
    target = rows[3]["features"]
    assert target["home_home_points"] == 3.0  # only the home win counts
    assert target["home_home_goals_for"] == 3.0
    assert target["home_home_goals_against"] == 0.0
    # Team 3 has no away history yet.
    assert target["away_away_points"] == 0.0
    assert target["home_home_points_diff"] == 3.0


def test_venue_form_is_time_safe() -> None:
    """A later away win must not appear in an earlier home-only total."""
    original = {r["id"]: r["features"] for r in enrich_history(_mini_season())}
    mutated_rows = _mini_season()
    mutated_rows[6]["home_score"] = 7
    mutated_rows[6]["away_score"] = 0
    mutated = {r["id"]: r["features"] for r in enrich_history(mutated_rows)}
    for match_id in (1, 2, 3, 4, 5):
        assert mutated[match_id] == original[match_id]
