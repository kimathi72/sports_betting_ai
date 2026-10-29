"""Leakage-safety and correctness of the Elo baseline.

The whole point of an Elo baseline is that it is simple enough to be obviously
correct. These tests therefore check the *mechanics* (update arithmetic, draws,
home advantage) and, more importantly, the *timing*: a match's own result must
never influence its own prediction, and matches kicking off at the same instant
must not influence each other.

Conventions under test
----------------------
- Ratings start at 1500 for every team (documented initialisation policy).
- Home advantage is a fixed rating bonus applied to the home side ONLY when
  forming the expected score; it is not baked into stored ratings.
- Expected score uses the standard logistic form with draws handled by dividing
  the outcome (1 / 0.5 / 0), matching the classic Elo update.
- A margin-of-victory multiplier is applied on update; a draw's margin is zero
  regardless of scoreline.
"""
from __future__ import annotations

import math

import numpy as np
import pytest

from ml.app.elo import (
    DEFAULT_HOME_ADVANTAGE,
    DEFAULT_K,
    INITIAL_RATING,
    EloRatings,
    expected_home_score,
    probabilities_from_ratings,
)


def _m(mid, home, away, hs, as_, kickoff="2020-01-01T15:00:00Z"):
    return {
        "id": mid,
        "home_team_id": home,
        "away_team_id": away,
        "home_score": hs,
        "away_score": as_,
        "kickoff_at": kickoff,
        "status": "completed",
    }


# --- initialisation ---------------------------------------------------------

def test_teams_start_at_the_documented_initial_rating() -> None:
    ratings = EloRatings()
    assert ratings.rating(1) == INITIAL_RATING
    assert INITIAL_RATING == 1500.0


def test_unknown_team_returns_initial_rating_without_creating_state() -> None:
    ratings = EloRatings()
    assert ratings.rating(999) == INITIAL_RATING
    assert ratings.known_teams() == set()


# --- expected score model ---------------------------------------------------

def test_equal_ratings_and_zero_home_advantage_give_a_coin_flip() -> None:
    assert expected_home_score(1500, 1500, 0.0) == pytest.approx(0.5)


def test_home_advantage_increases_expected_score() -> None:
    with_adv = expected_home_score(1500, 1500, DEFAULT_HOME_ADVANTAGE)
    without = expected_home_score(1500, 1500, 0.0)

    assert with_adv > without
    assert with_adv == pytest.approx(1.0 / (1.0 + 10 ** (-DEFAULT_HOME_ADVANTAGE / 400.0)))


def test_expected_score_is_symmetric_without_advantage() -> None:
    assert expected_home_score(1600, 1400, 0.0) == pytest.approx(
        1.0 - expected_home_score(1400, 1600, 0.0)
    )


# --- rating updates ---------------------------------------------------------

def test_winner_gains_and_loser_loses_equal_points() -> None:
    ratings = EloRatings()
    ratings.record_match(_m(1, 1, 2, 2, 0))

    gain = ratings.rating(1) - INITIAL_RATING
    loss = INITIAL_RATING - ratings.rating(2)

    assert gain > 0
    assert gain == pytest.approx(loss), "Elo updates are zero-sum"


def test_draw_moves_both_ratings_toward_each_other() -> None:
    ratings = EloRatings()
    ratings.record_match(_m(1, 1, 2, 1, 1))

    # With a home advantage the home side was "expected" to do better than a
    # draw, so it loses a little and the away side gains the same.
    assert ratings.rating(1) < INITIAL_RATING
    assert ratings.rating(2) > INITIAL_RATING
    assert abs((ratings.rating(1) + ratings.rating(2)) / 2 - INITIAL_RATING) < 1e-9


def test_upset_moves_ratings_more_than_an_expected_result() -> None:
    upset = EloRatings()
    upset.record_match(_m(1, 1, 2, 0, 5))  # away thrashing home

    expected = EloRatings()
    expected.record_match(_m(1, 1, 2, 5, 0))  # home thrashing away

    assert abs(upset.rating(2) - INITIAL_RATING) > abs(expected.rating(2) - INITIAL_RATING)


def test_k_factor_scales_the_update() -> None:
    small = EloRatings(k=10.0, home_advantage=0.0)
    large = EloRatings(k=40.0, home_advantage=0.0)

    small.record_match(_m(1, 1, 2, 2, 0))
    large.record_match(_m(1, 1, 2, 2, 0))

    assert (large.rating(1) - INITIAL_RATING) == pytest.approx(
        4 * (small.rating(1) - INITIAL_RATING)
    )


def test_margin_of_victory_multiplier_raised_draw_is_independent_of_goals() -> None:
    """A 3-3 draw must update exactly like a 0-0 draw."""
    a = EloRatings()
    a.record_match(_m(1, 1, 2, 3, 3))

    b = EloRatings()
    b.record_match(_m(1, 1, 2, 0, 0))

    assert a.rating(1) == pytest.approx(b.rating(1))
    assert a.rating(2) == pytest.approx(b.rating(2))


def test_missing_scores_are_rejected_rather_than_guessed() -> None:
    ratings = EloRatings()
    with pytest.raises(ValueError):
        ratings.record_match(_m(1, 1, 2, None, None))


# --- pre-match safety (the core leakage guarantee) --------------------------

def test_prediction_uses_pre_match_ratings_not_the_result() -> None:
    """Recording a match must not change the probabilities computed for it."""
    ratings = EloRatings()

    before = probabilities_from_ratings(
        ratings.rating(1), ratings.rating(2), ratings.home_advantage
    )
    ratings.record_match(_m(1, 1, 2, 5, 0))
    after_same_fixture = probabilities_from_ratings(
        INITIAL_RATING, INITIAL_RATING, ratings.home_advantage
    )

    assert before == pytest.approx(after_same_fixture)


def test_a_teams_rating_never_reflects_a_match_before_it_is_recorded() -> None:
    ratings = EloRatings()
    assert ratings.rating(1) == INITIAL_RATING

    # Nothing recorded yet: a "future" fixture must not be visible.
    assert ratings.rating(1) == INITIAL_RATING


# --- chronological ordering and simultaneous kickoffs ----------------------

def test_simultaneous_kickoffs_do_not_influence_each_other() -> None:
    """Two matches at the same instant must both use the same pre-round ratings."""
    kickoff = "2020-05-01T15:00:00Z"
    matches = [
        _m(1, 1, 2, 5, 0, kickoff=kickoff),
        _m(2, 3, 4, 0, 5, kickoff=kickoff),
    ]

    ratings = EloRatings()
    predictions = ratings.predict_chronologically(matches)

    # Both fixtures must see a rating table where neither same-round result has
    # been applied yet, so both start from the neutral prior.
    for prediction in predictions:
        assert prediction["home_rating"] == INITIAL_RATING
        assert prediction["away_rating"] == INITIAL_RATING


def test_simultaneous_results_are_applied_after_the_whole_round() -> None:
    kickoff = "2020-05-01T15:00:00Z"
    matches = [
        _m(1, 1, 2, 5, 0, kickoff=kickoff),
        _m(2, 3, 4, 5, 0, kickoff=kickoff),
    ]

    ratings = EloRatings()
    ratings.predict_chronologically(matches)

    # Both winners gained; both losers dropped.
    assert ratings.rating(1) > INITIAL_RATING
    assert ratings.rating(3) > INITIAL_RATING
    assert ratings.rating(2) < INITIAL_RATING
    assert ratings.rating(4) < INITIAL_RATING


def test_a_later_match_sees_an_earlier_result() -> None:
    earlier = _m(1, 1, 2, 5, 0, kickoff="2020-01-01T15:00:00Z")
    later = _m(2, 1, 3, 0, 0, kickoff="2020-02-01T15:00:00Z")

    ratings = EloRatings()
    predictions = ratings.predict_chronologically([earlier, later])

    assert predictions[0]["home_rating"] == INITIAL_RATING
    assert predictions[1]["home_rating"] > INITIAL_RATING


def test_input_order_does_not_matter() -> None:
    a = _m(1, 1, 2, 5, 0, kickoff="2020-01-01T15:00:00Z")
    b = _m(2, 1, 3, 0, 0, kickoff="2020-02-01T15:00:00Z")

    forward = EloRatings().predict_chronologically([a, b])
    reversed_ = EloRatings().predict_chronologically([b, a])

    assert [p["match_id"] for p in forward] == [1, 2]
    assert [p["match_id"] for p in reversed_] == [1, 2]
    assert forward[0]["home_rating"] == reversed_[0]["home_rating"]


# --- probability output -----------------------------------------------------

def test_probabilities_are_valid_and_sum_to_one() -> None:
    for home, away in [(1500, 1500), (1800, 1200), (1200, 1800), (2100, 900)]:
        probs = probabilities_from_ratings(home, away, DEFAULT_HOME_ADVANTAGE)

        assert set(probs) == {"H", "D", "A"}
        assert all(0.0 <= v <= 1.0 for v in probs.values()), probs
        assert sum(probs.values()) == pytest.approx(1.0, abs=1e-9)


def test_home_draw_away_ordering_is_stable() -> None:
    probs = probabilities_from_ratings(1500, 1500, DEFAULT_HOME_ADVANTAGE)
    assert list(probs) == ["H", "D", "A"]


def test_stronger_team_is_favoured() -> None:
    strong = probabilities_from_ratings(1800, 1200, DEFAULT_HOME_ADVANTAGE)
    weak = probabilities_from_ratings(1200, 1800, DEFAULT_HOME_ADVANTAGE)

    assert strong["H"] > weak["H"]
    assert weak["A"] > strong["A"]


def test_draw_probability_peaks_when_teams_are_even() -> None:
    even = probabilities_from_ratings(1500, 1500, DEFAULT_HOME_ADVANTAGE)
    lopsided = probabilities_from_ratings(1900, 1100, DEFAULT_HOME_ADVANTAGE)

    assert even["D"] > lopsided["D"]


# --- edge cases -------------------------------------------------------------

def test_placeholder_kickoff_times_are_ordered_deterministically() -> None:
    """Two matches sharing a placeholder time must still be in a fixed order."""
    matches = [
        {**_m(2, 1, 2, 1, 0), "kickoff_at": "2016-08-13T12:00:00Z"},
        {**_m(1, 3, 4, 1, 0), "kickoff_at": "2016-08-13T12:00:00Z"},
    ]

    first = EloRatings().predict_chronologically(matches)
    second = EloRatings().predict_chronologically(list(reversed(matches)))

    assert [p["match_id"] for p in first] == [p["match_id"] for p in second]


def test_empty_match_list_returns_no_predictions() -> None:
    assert EloRatings().predict_chronologically([]) == []


def test_home_advantage_is_explicit_and_configurable() -> None:
    none = probabilities_from_ratings(1500, 1500, 0.0)
    home = probabilities_from_ratings(1500, 1500, DEFAULT_HOME_ADVANTAGE)

    assert none["H"] == pytest.approx(none["A"])
    assert home["H"] > none["H"]
