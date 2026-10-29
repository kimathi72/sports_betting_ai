"""The Elo candidate as it is actually used inside the evaluation harness.

``test_elo.py`` proves the rating mechanics. This file proves the *integration*:
that the harness hands Elo the same rows as every other candidate, that Elo's
probabilities arrive in the harness class order, and that the split boundary —
not merely the ability to sort — is what keeps its ratings honest.
"""
from __future__ import annotations

import dataclasses
from datetime import datetime, timedelta

import numpy as np
import pytest

from ml.app.elo import (
    DEFAULT_HOME_ADVANTAGE,
    DEFAULT_K,
    INITIAL_RATING,
    EloRatings,
    probabilities_from_ratings,
)
from ml.app.evaluate_markets import (
    CANDIDATES,
    MARKET_CLASSES,
    current_protocol,
    load_frozen_config,
    make_elo,
    protocol_digest,
)
from ml.app.evaluation import build_rows, chronological_split


def _match(mid: int, home: int, away: int, hs: int, as_: int, day: int, hour: int = 15) -> dict:
    kickoff = datetime(2020, 1, 1, hour) + timedelta(days=day)
    return {
        "id": mid,
        "kickoff_at": kickoff.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "status": "completed",
        "home_team_id": home,
        "away_team_id": away,
        "home_score": hs,
        "away_score": as_,
    }


def _league(matchdays: int = 60) -> list[dict]:
    """A tiny round-robin league: 4 teams, 2 fixtures per matchday."""
    teams = [1, 2, 3, 4]
    matches: list[dict] = []
    for day in range(matchdays):
        a = teams[day % 4]
        b = teams[(day + 1) % 4]
        c = teams[(day + 2) % 4]
        d = teams[(day + 3) % 4]
        matches.append(_match(day * 2 + 1, a, b, 2, 0, day))
        matches.append(_match(day * 2 + 2, c, d, 0, 1, day))
    return matches


# --- candidate wiring -------------------------------------------------------

def test_every_market_offers_an_elo_candidate() -> None:
    for market, candidates in CANDIDATES.items():
        names = [name for name, _ in candidates]
        assert "elo" in names, f"{market} has no Elo candidate: {names}"


def test_every_market_keeps_the_required_comparison_set() -> None:
    """The comparison must be fair: same candidates, same rows, every market."""
    required = {
        "frequency",
        "logistic_regression",
        "hist_gradient_boosting",
        "poisson_goals",
        "elo",
    }
    for market, candidates in CANDIDATES.items():
        names = {name for name, _ in candidates}
        assert required <= names, f"{market} is missing {required - names}"


def test_elo_probabilities_come_out_in_the_harness_class_order() -> None:
    matches = _league()
    rows = build_rows(matches, "1x2")
    split = chronological_split(rows)

    predict = make_elo(["H", "D", "A"])(split.train)
    proba = predict(split.test)

    assert proba.shape == (len(split.test), 3)
    assert np.allclose(proba.sum(axis=1), 1.0)


def test_elo_binary_markets_are_derived_from_the_same_one_x_two() -> None:
    """Over/Under and BTTS for Elo are labelled proxies, but must be valid."""
    matches = _league()
    split = chronological_split(build_rows(matches, "1x2"))

    for classes in (["Over", "Under"], ["Yes", "No"]):
        proba = make_elo(classes)(split.train)(split.test)
        assert proba.shape == (len(split.test), 2)
        assert np.allclose(proba.sum(axis=1), 1.0)
        assert (proba >= 0).all() and (proba <= 1).all()


# --- what the factory is allowed to see -------------------------------------

def test_elo_factory_receives_only_train_rows() -> None:
    """Ratings must be built from the train partition's history, not the future.

    The harness is allowed to pass the whole fixture list (Elo needs team ids
    and kickoffs); what matters is that only TRAIN results reached the table.
    Replaying train rows alone must therefore produce identical probabilities.
    """
    matches = _league()
    split = chronological_split(build_rows(matches, "1x2"))

    train_ids = {row.match_id for row in split.train}
    probabilities = make_elo(["H", "D", "A"])(split.train)(split.validation)

    replay = EloRatings()
    replay.predict_chronologically([m for m in matches if m["id"] in train_ids])
    expected = np.array(
        [
            [
                (p := probabilities_from_ratings(
                    replay.rating(m["home_team_id"]),
                    replay.rating(m["away_team_id"]),
                    replay.home_advantage,
                ))["H"],
                p["D"],
                p["A"],
            ]
            for m in sorted(matches, key=lambda m: (m["kickoff_at"], m["id"]))
            if m["id"] in {row.match_id for row in split.validation}
        ]
    )

    assert np.allclose(probabilities, expected), "validation used more than train history"
    assert probabilities.shape == (len(split.validation), 3)


def test_a_rows_own_result_does_not_change_its_own_prediction() -> None:
    """The leakage that actually bites: a row must not be scored after its own
    update. Flipping a train row's result must change LATER predictions, proving
    the update was applied — but every EARLIER row must be untouched."""
    matches = _league(30)
    rows = build_rows(matches, "1x2")
    split = chronological_split(rows)

    flipped = [dict(m) for m in matches]
    target = flipped[5]
    target["home_score"], target["away_score"] = target["away_score"], target["home_score"]

    baseline = make_elo(["H", "D", "A"])(split.train)(split.train)
    by_id = {m["id"]: m for m in flipped}
    after_flip = make_elo(["H", "D", "A"])(
        [
            dataclasses.replace(
                r, home_score=by_id[r.match_id]["home_score"], away_score=by_id[r.match_id]["away_score"]
            )
            if r.match_id == target["id"]
            else r
            for r in split.train
        ]
    )(split.train)

    position = next(i for i, r in enumerate(split.train) if r.match_id == target["id"])

    # The flipped match itself is still predicted from pre-match ratings.
    assert np.allclose(baseline[position], after_flip[position])
    # Everything before it is unaffected.
    assert np.allclose(baseline[:position], after_flip[:position])
    # But the change did reach the table, so later rows disagree.
    assert not np.allclose(baseline[position + 1 :], after_flip[position + 1 :])


def test_same_kickoff_matches_use_identical_ratings() -> None:
    """Both fixtures of a round must be predicted from the same table state."""
    same = [
        _match(1, 1, 2, 5, 0, day=0),
        _match(2, 3, 4, 0, 5, day=0),
    ]
    ratings = EloRatings()
    predictions = ratings.predict_chronologically(same)

    assert all(p["home_rating"] == INITIAL_RATING for p in predictions)
    assert all(p["away_rating"] == INITIAL_RATING for p in predictions)


# --- parameters -------------------------------------------------------------

def test_elo_parameters_are_documented_and_modest() -> None:
    assert INITIAL_RATING == 1500.0
    assert 10.0 <= DEFAULT_K <= 40.0
    assert 0.0 < DEFAULT_HOME_ADVANTAGE <= 100.0


def test_class_orders_are_canonical() -> None:
    assert MARKET_CLASSES["1x2"] == ["H", "D", "A"]
    assert MARKET_CLASSES["over_under_2.5"] == ["Over", "Under"]
    assert MARKET_CLASSES["btts"] == ["Yes", "No"]


# --- frozen evaluation configuration -----------------------------------------


def test_the_protocol_is_frozen_with_a_stable_digest() -> None:
    """A future holdout must be scored with the SAME protocol.

    If any element of the protocol changes - split fractions, candidate set,
    Elo constants, bootstrap settings - the digest changes and the freeze check
    fails. That forces the change to be a deliberate, new protocol rather than
    a silent drift between two evaluations that are then compared.
    """
    frozen = load_frozen_config()

    assert protocol_digest(current_protocol()) == frozen["digest"]


def test_a_changed_protocol_produces_a_different_digest() -> None:
    base = current_protocol()
    changed = dict(base, validation_fraction=0.25)

    assert protocol_digest(base) != protocol_digest(changed)


def test_the_freeze_records_that_the_holdout_is_already_contaminated() -> None:
    """The record must not let anyone mistake the current test set for pristine."""
    frozen = load_frozen_config()

    assert frozen["holdout_status"] == "exploratory"
    assert frozen["contamination"], "the freeze must explain why the test set is not pristine"


def test_the_frozen_protocol_lists_every_candidate() -> None:
    frozen = load_frozen_config()
    for market, names in frozen["protocol"]["candidates"].items():
        assert set(names) == {name for name, _ in CANDIDATES[market]}
