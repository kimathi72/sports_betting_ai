"""Leakage-safe Elo rating baseline for 1X2.

WHY ELO
-------
A frequency baseline proves the harness works but says nothing about whether the
features carry signal. Elo is the cheapest model that does: it is deterministic,
has three hand-sized parameters, and its only learned state is one number per
team. If a 17-feature gradient booster cannot beat it, that is a finding worth
reporting rather than hiding behind a comparison against a coin flip.

WHY IT IS WRITTEN THIS WAY
--------------------------
Every bug an Elo implementation can have is a timing bug: an update applied
before the prediction that depends on it. This module therefore makes the timing
impossible to get wrong rather than merely testing for it:

* Predictions and updates are the *same loop*. ``predict_chronologically``
  reads the rating table, emits a probability, and only then applies the
  updates for that match. There is no code path that can predict after update.
* Matches are grouped by identical kickoff timestamp. A whole round is
  predicted from the ratings in force at the start of the round, and every
  result in the round is applied afterwards. Two teams playing simultaneously
  can therefore never see each other's result, and a team cannot see a result
  from the same round.
* Input order is irrelevant. Matches are sorted by ``(kickoff_at, id)`` — the
  same total order the rest of the ML pipeline uses — so a shuffled or reversed
  list produces identical output. Identical timestamps fall back to match id,
  which makes "simultaneous" mean "same instant", not "whatever order the
  caller happened to supply".

PARAMETERS (deliberately modest and NOT tuned on this dataset)
--------------------------------------------------------------
``K = 20``       World Football Elo Ratings standard; well inside the range
                 (10-40) where a football league's ratings still move.
``HOME_ADVANTAGE = 60``
                 ≈ the 60-65 point home edge reported for European domestic
                 leagues in the World Football Elo Ratings; applied only when
                 forming the expected score, never baked into stored ratings.
``DEFAULT_DRAW_RATE = 0.25``
                 League-typical draw frequency. Used only to convert the
                 expected score into three probabilities (see below).
``MOV=1.0``      No margin-of-victory multiplier. A 5-0 and a 1-0 are the same
                 update. MoV inflates ratings for strong-team blowouts and adds
                 a fitted parameter for a market that does not grade margins.

Because no parameter was fitted or selected, the model cannot have been tuned on
the validation partition. That is the point: it is a fixed reference, not a
competitor to be optimised.

FROM EXPECTED SCORE TO THREE PROBABILITIES
------------------------------------------
Classic Elo produces a single home "expected score" in [0, 1] where a draw counts
half. Three outcomes are recovered with a draw model: the draw probability is
anchor * DRAW_RATE, scaled by how even the two sides are (4 * w * (1 - w), which
peaks at exactly 1 for a coin flip and decays to 0 for a mismatch), and the
remaining mass is split between H and A in proportion to the expected score.
The result is normalised, so the output is always a valid distribution summing
to 1 with columns in ``("H", "D", "A")`` order.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Sequence

INITIAL_RATING = 1500.0
DEFAULT_K = 20.0
DEFAULT_HOME_ADVANTAGE = 60.0
DEFAULT_DRAW_RATE = 0.25

# A placeholder kickoff (e.g. every match of a matchday stamped 12:00) must
# still yield a stable order, so ties break on match id. This is documented
# rather than hoped for: it is what makes the output reproducible.
_UNKNOWN_KICKOFF = ""


# ---------------------------------------------------------------------------
# Pure arithmetic
# ---------------------------------------------------------------------------

def expected_home_score(
    home_rating: float, away_rating: float, home_advantage: float = DEFAULT_HOME_ADVANTAGE
) -> float:
    """Standard logistic Elo expectation for the home side, including home advantage.

    ``home_advantage`` is a rating-point bonus added to the home rating only for
    this calculation. It is never stored, so a team's rating stays venue-neutral.
    """
    return 1.0 / (1.0 + 10.0 ** (-(home_rating + home_advantage - away_rating) / 400.0))


def outcome_multiplier(home_score: int, away_score: int) -> float:
    """Margin-of-victory term. Deliberately 1.0 for every result.

    Kept as a named function so the policy is visible and changeable in one
    place; the constant is documented in the module docstring.
    """
    return 1.0


def probabilities_from_ratings(
    home_rating: float,
    away_rating: float,
    home_advantage: float = DEFAULT_HOME_ADVANTAGE,
    draw_rate: float = DEFAULT_DRAW_RATE,
) -> dict[str, float]:
    """Expected score -> normalised (H, D, A) distribution."""
    w = expected_home_score(home_rating, away_rating, home_advantage)

    # Draw probability peaks when the sides are even and vanishes in a mismatch.
    p_draw = draw_rate * 4.0 * w * (1.0 - w)
    p_draw = min(max(p_draw, 0.0), 0.999)

    decisive = 1.0 - p_draw
    h = w * decisive
    d = p_draw
    a = (1.0 - w) * decisive

    total = h + d + a
    return {"H": h / total, "D": d / total, "A": a / total}


# ---------------------------------------------------------------------------
# Rating table
# ---------------------------------------------------------------------------

@dataclass
class EloRatings:
    """Mutable rating table plus the chronological driver.

    ``k``, ``home_advantage`` and ``draw_rate`` are constructor arguments so a
    caller can inspect sensitivity, but the defaults are the documented policy.
    """

    k: float = DEFAULT_K
    home_advantage: float = DEFAULT_HOME_ADVANTAGE
    draw_rate: float = DEFAULT_DRAW_RATE
    ratings: dict[int, float] = field(default_factory=dict)

    # -- state -------------------------------------------------------------

    def rating(self, team_id: int) -> float:
        """Current rating. Reading an unknown team does not create storage."""
        return self.ratings.get(team_id, INITIAL_RATING)

    def known_teams(self) -> set[int]:
        return set(self.ratings)

    # -- single match ------------------------------------------------------

    def record_match(self, match: dict) -> None:
        """Apply one completed result to the rating table.

        Missing scores are a data error, not an excuse to invent a result, so
        they raise rather than being skipped.
        """
        home_id, away_id = _team_ids(match)
        home_score, away_score = _scores(match)
        self._apply(home_id, away_id, home_score, away_score)

    def _apply(self, home_id: int, away_id: int, home_score: int, away_score: int) -> None:
        home_rating = self.rating(home_id)
        away_rating = self.rating(away_id)

        expectation = expected_home_score(home_rating, away_rating, self.home_advantage)

        if home_score > away_score:
            actual = 1.0
        elif home_score == away_score:
            actual = 0.5
        else:
            actual = 0.0

        # Zero-sum: whatever the home side gains, the away side loses. Stored
        # ratings therefore keep a fixed total, which makes drift visible.
        delta = self.k * outcome_multiplier(home_score, away_score) * (actual - expectation)
        self.ratings[home_id] = home_rating + delta
        self.ratings[away_id] = away_rating - delta

    # -- chronological driver ---------------------------------------------

    def predict_chronologically(self, matches: Sequence[dict]) -> list[dict]:
        """Predict every match from pre-match ratings, then update round by round.

        Returns one dict per match, sorted by ``(kickoff_at, id)``, carrying the
        probabilities and the ratings they were derived from. Matches lacking
        final scores still receive a prediction (that is the useful case in
        production) but contribute no update.
        """
        ordered = sorted(matches, key=_chronological_key)
        predictions: list[dict] = []

        for round_matches in _group_by_kickoff(ordered):
            # Phase 1: predict the whole round from the ratings at round start.
            pending: list[tuple[int, int, int, int]] = []
            for match in round_matches:
                home_id, away_id = _team_ids(match)

                predictions.append(
                    {
                        "match_id": match.get("id"),
                        "kickoff_at": match.get("kickoff_at"),
                        "home_team_id": home_id,
                        "away_team_id": away_id,
                        "home_rating": self.rating(home_id),
                        "away_rating": self.rating(away_id),
                        "probabilities": probabilities_from_ratings(
                            self.rating(home_id),
                            self.rating(away_id),
                            self.home_advantage,
                            self.draw_rate,
                        ),
                    }
                )

                scores = _optional_scores(match)
                if scores is not None:
                    pending.append((home_id, away_id, scores[0], scores[1]))

            # Phase 2: apply the round's results afterwards.
            for home_id, away_id, home_score, away_score in pending:
                self._apply(home_id, away_id, home_score, away_score)

        return predictions


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _chronological_key(match: dict) -> tuple[str, int]:
    """Total order on fixtures: kickoff first, match id to break ties.

    A missing, null or blank kickoff sorts first under an empty string, which is
    deterministic. Match id then keeps every repeated timestamp in a fixed order
    regardless of how the caller supplied the list.
    """
    kickoff = match.get("kickoff_at")
    kickoff = "" if kickoff is None else str(kickoff)
    match_id = match.get("id")
    return (kickoff, match_id if isinstance(match_id, int) else -1)


def _group_by_kickoff(ordered: Sequence[dict]) -> list[list[dict]]:
    rounds: list[list[dict]] = []
    for match in ordered:
        key = _chronological_key(match)[0]
        if rounds and _chronological_key(rounds[-1][0])[0] == key:
            rounds[-1].append(match)
        else:
            rounds.append([match])
    return rounds


def _team_ids(match: dict) -> tuple[int, int]:
    home_id = match.get("home_team_id")
    away_id = match.get("away_team_id")
    if home_id is None or away_id is None:
        raise ValueError(f"match {match.get('id')} is missing a team id")
    return int(home_id), int(away_id)


def _optional_scores(match: dict) -> tuple[int, int] | None:
    home, away = match.get("home_score"), match.get("away_score")
    if home is None or away is None:
        return None
    return int(home), int(away)


def _scores(match: dict) -> tuple[int, int]:
    scores = _optional_scores(match)
    if scores is None:
        raise ValueError(f"match {match.get('id')} has no final score")
    return scores
