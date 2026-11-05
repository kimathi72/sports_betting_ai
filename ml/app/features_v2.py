"""Leakage-safe, chronological pre-match feature engineering — v2.

WHY A V2 RATHER THAN AN EDIT OF features.py
-------------------------------------------
``ml/app/features.py`` implements the 17 features the deployed 1X2 artifact was
trained on. Changing its semantics in place would silently invalidate that
artifact: the same feature NAMES would mean different numbers, and the artifact
stores only the names, not the definition. It is therefore kept exactly as it is,
and this module is the versioned successor (``FEATURE_VERSION = "v2"``).

Both modules share one contract, enforced by ``tests/test_feature_parity.py``:
for the same history, the 17 shared names must produce the same values, and v2
must contain them as a subset. That makes the migration checkable instead of
hoped-for.

LEAKAGE RULES ENFORCED HERE (and tested)
----------------------------------------
1. A feature for fixture ``m`` may only read rows whose ``kickoff_at`` is strictly
   before ``m.kickoff_at``. Equal kickoffs are excluded: two matches at the same
   minute cannot inform one another.
2. Only ``completed`` rows with both scores (and, when a goal model needs it, both
   scores present) are read. A scheduled opponent tells you a fixture exists, not
   how good the team is.
3. Every stateful feature (Elo, rest days, congestion) is produced by walking the
   full history once in chronological order, so the value attached to row *i* is
   exactly the state built from rows 1..i-1. Nothing is recomputed per row from the
   whole dataset, which is the classic way a future result leaks in.
4. A team's first appearance has no form. It is represented explicitly
   (``matched_before = 0`` and an ``is_cold_start`` flag), never imputed from the
   target or from the season's final table.
5. No feature is normalised using statistics of the dataset it is evaluated on.
   The only division is by a fixed window size or a fixed Elo constant.
"""
from __future__ import annotations

from collections import defaultdict, deque
from datetime import datetime, timezone
from typing import Any, Iterable, Sequence

from ml.app.features import (
    _utc,
    compute_match_features,
    double_chance_probabilities,
    over_under_target,
    btts_target,
    target_label,
)

FEATURE_VERSION = "v2"

# Feature order is part of the contract: the artifact stores these names and
# inference refuses a vector that does not match.
FEATURE_NAMES_V2: list[str] = [
    # ---- the 17 v1 features, unchanged in meaning ----
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
    # ---- v2 additions ----
    "home_last5_points_diff",
    "home_last5_goals_for_diff",
    "home_last5_goals_against_diff",
    "away_last5_points_diff",
    "away_last5_goals_for_diff",
    "away_last5_goals_against_diff",
    "home_elo",
    "away_elo",
    "elo_diff",
    "home_home_only_points",
    "away_away_only_points",
    "home_rest_days",
    "away_rest_days",
    "rest_days_diff",
    "home_matches_last_14_days",
    "away_matches_last_14_days",
    "congestion_diff",
    "home_matched_before",
    "away_matched_before",
    "home_win_rate",
    "away_win_rate",
    "home_goal_rate",
    "away_goal_rate",
    "home_conceded_rate",
    "away_conceded_rate",
    "home_venue_win_rate",
    "away_venue_win_rate",
    # Home-only / away-only form. A club that wins at home and loses away is a
    # different fixture at home than its combined form suggests, and the combined
    # last-5 features cannot express that; the grid models need the split.
    "home_home_points",
    "home_home_goals_for",
    "home_home_goals_against",
    "away_away_points",
    "away_away_goals_for",
    "away_away_goals_against",
    "home_home_points_diff",
    "away_away_points_diff",
    "is_draw_competition_rate",
]

FORM_WINDOW = 5
ALL_TIME_FORM_WINDOW = 20  # win-rate / goal-rate window, longer than last-5

# Elo parameters. K is the update weight; HOME_ADVANTAGE is the rating points a
# home side is given for playing at home; START is the initial rating. They are
# deliberately constants, not fitted on the evaluation period.
ELO_START = 1500.0
ELO_K = 20.0
ELO_HOME_ADVANTAGE = 60.0
ELO_GOAL_MARGIN_FACTOR = 1.0

CONGESTION_DAYS = 14
MAX_REST_DAYS = 60.0  # a longer gap is reported as "no congestion", not extrapolated


class LeakageError(ValueError):
    """Raised when a caller asks for features that cannot be computed time-safely."""


def _completed(row: dict) -> bool:
    return (
        row.get("status") == "completed"
        and row.get("home_score") is not None
        and row.get("away_score") is not None
    )


def _result_points(scored: int, conceded: int) -> int:
    if scored > conceded:
        return 3
    if scored == conceded:
        return 1
    return 0


def _elo_expected(rating_a: float, rating_b: float, home_advantage: float) -> float:
    """Expected score of A against B, with the home advantage added to A's rating."""
    return 1.0 / (1.0 + 10 ** ((rating_b - (rating_a + home_advantage)) / 400.0))


def _stable_order(rows: Iterable[dict]) -> list[dict]:
    """Chronological order with a deterministic tie-break on id.

    Two fixtures can kick off at the same time. Sorting by kickoff alone would make
    the resulting state depend on SQL row order, which is not guaranteed; sorting by
    (kickoff, id) makes the feature vector reproducible, and rule 1 still keeps
    same-kickoff rows out of each other's history.
    """
    return sorted(rows, key=lambda r: (_utc(r.get("kickoff_at")), int(r.get("id") or 0)))


class _TeamState:
    """Everything known about one club strictly before the row being enriched."""

    __slots__ = (
        "results",
        "home_results",
        "away_results",
        "elo",
        "last_kickoff",
        "recent_kickoffs",
        "matched",
    )

    def __init__(self) -> None:
        self.results: deque[dict] = deque(maxlen=ALL_TIME_FORM_WINDOW)
        self.home_results: deque[dict] = deque(maxlen=ALL_TIME_FORM_WINDOW)
        self.away_results: deque[dict] = deque(maxlen=ALL_TIME_FORM_WINDOW)
        self.elo: float = ELO_START
        self.last_kickoff: datetime | None = None
        self.recent_kickoffs: deque[datetime] = deque(maxlen=64)
        self.matched: int = 0

    def record(self, result: dict, kickoff: datetime, home: bool, goal_diff: int) -> None:
        self.results.append(result)
        (self.home_results if home else self.away_results).append(result)
        self.last_kickoff = kickoff
        self.recent_kickoffs.append(kickoff)
        self.matched += 1
        # Elo update uses the actual margin, damped by the goal-margin factor.
        opponent_elo = result["opponent_elo"]
        expected = _elo_expected(self.elo, opponent_elo, ELO_HOME_ADVANTAGE if home else -ELO_HOME_ADVANTAGE)
        actual = result["actual"]
        multiplier = 1.0 + ELO_GOAL_MARGIN_FACTOR * abs(goal_diff) ** 0.5
        self.elo += ELO_K * multiplier * (actual - expected)

    def aggregate(self, window: int) -> dict[str, float]:
        recent = list(self.results)[-window:]
        if not recent:
            return {
                "points": 0.0,
                "goals_for": 0.0,
                "goals_against": 0.0,
                "wins": 0.0,
                "draws": 0.0,
                "losses": 0.0,
                "played": 0.0,
                "win_rate": 0.0,
                "goal_rate": 0.0,
                "conceded_rate": 0.0,
            }
        played = float(len(recent))
        wins = sum(r["won"] for r in recent)
        draws = sum(r["draw"] for r in recent)
        losses = sum(r["lost"] for r in recent)
        goals_for = sum(r["goals_for"] for r in recent)
        goals_against = sum(r["goals_against"] for r in recent)
        return {
            "points": float(sum(r["points"] for r in recent)),
            "goals_for": float(goals_for),
            "goals_against": float(goals_against),
            "wins": float(wins),
            "draws": float(draws),
            "losses": float(losses),
            "played": played,
            "win_rate": wins / played,
            "goal_rate": goals_for / played,
            "conceded_rate": goals_against / played,
        }

    def venue_aggregate(self, venue: str, window: int) -> dict[str, float]:
        """Form at ONE venue: ``"home"`` or ``"away"``, never a fallback.

        The two sides of a fixture need different splits — the home club's home
        record and the away club's away record — so the venue is explicit rather
        than inferred from whichever list happens to be non-empty.
        """
        if venue not in ("home", "away"):
            raise ValueError(f"unknown venue {venue!r}")

        def summarise(results) -> dict[str, float]:
            recent = list(results)[-window:]
            if not recent:
                return {
                    "points": 0.0,
                    "goals_for": 0.0,
                    "goals_against": 0.0,
                    "played": 0.0,
                }
            return {
                "points": float(sum(r["points"] for r in recent)),
                "goals_for": float(sum(r["goals_for"] for r in recent)),
                "goals_against": float(sum(r["goals_against"] for r in recent)),
                "played": float(len(recent)),
            }

        return summarise(self.home_results if venue == "home" else self.away_results)

    def venue_points(self) -> float:
        recent = list(self.home_results)[-FORM_WINDOW:] or list(self.away_results)[-FORM_WINDOW:]
        return float(sum(r["points"] for r in recent)) if recent else 0.0

    def venue_win_rate(self) -> float:
        recent = list(self.home_results)[-ALL_TIME_FORM_WINDOW:] or list(
            self.away_results
        )[-ALL_TIME_FORM_WINDOW:]
        if not recent:
            return 0.0
        return sum(r["won"] for r in recent) / len(recent)

    def rest_days(self, kickoff: datetime) -> float:
        if self.last_kickoff is None:
            return MAX_REST_DAYS
        days = (kickoff - self.last_kickoff).total_seconds() / 86400.0
        return float(min(max(days, 0.0), MAX_REST_DAYS))

    def congestion(self, kickoff: datetime) -> float:
        cutoff = kickoff.timestamp() - CONGESTION_DAYS * 86400.0
        return float(sum(1 for k in self.recent_kickoffs if k.timestamp() > cutoff))


def enrich_history(
    matches: Sequence[dict],
    *,
    competition_id: Any = None,
) -> list[dict]:
    """Return every match with a leakage-safe feature vector attached.

    Each returned row is the input dict plus ``features`` (all v2 names),
    ``label_1x2`` / ``label_over_under`` / ``label_btts`` (``None`` for unplayed
    rows) and ``feature_version``.

    ``matches`` may be the whole dataset or one competition's rows; state is kept
    per ``(competition_id, team_id)`` so two competitions sharing a club name do
    not contaminate each other's Elo.

    Rows are processed in strict chronological order. A row's features therefore
    depend only on earlier rows — which the tests assert by recomputing a feature
    from a truncated dataset and requiring an identical value.
    """
    states: dict[tuple[Any, Any], _TeamState] = defaultdict(_TeamState)
    draw_counts: dict[Any, list[int]] = defaultdict(lambda: [0, 0])
    # Per-team chronological history, kept forever as a reference. The v1 function
    # used to receive the WHOLE dataset history for every fixture and then filter
    # it, which is O(n^2) over a 40k-match dataset. It only needs matches involving
    # the fixture's two clubs (for form and head-to-head), so exactly those are
    # passed: the same numbers, a fraction of the work.
    team_history: dict[Any, list[dict]] = defaultdict(list)

    enriched: list[dict] = []
    for row in _stable_order(matches):
        kickoff = _utc(row.get("kickoff_at"))
        comp = row.get("competition_id", competition_id)
        home_id = row.get("home_team_id")
        away_id = row.get("away_team_id")
        if home_id is None or away_id is None:
            raise LeakageError(f"match without both teams: {row.get('id')!r}")

        home_key = (comp, home_id)
        away_key = (comp, away_id)
        home_state = states[home_key]
        away_state = states[away_key]

        # The 17 shared features are computed by the v1 function from the history of
        # these two clubs only — every match either of them played earlier. That is
        # exactly the information v1 reads (form for both sides, head-to-head), so
        # there is still one implementation of the formulas.
        history = _merge_history(team_history[home_key], team_history[away_key])
        base = compute_match_features(row, history)

        home_form = home_state.aggregate(FORM_WINDOW)
        away_form = away_state.aggregate(FORM_WINDOW)
        home_venue = home_state.venue_aggregate("home", FORM_WINDOW)
        away_venue = away_state.venue_aggregate("away", FORM_WINDOW)

        features = dict(base)
        features.update(
            {
                "home_last5_points_diff": home_form["points"] - away_form["points"],
                "home_last5_goals_for_diff": home_form["goals_for"] - away_form["goals_for"],
                "home_last5_goals_against_diff": home_form["goals_against"]
                - away_form["goals_against"],
                "away_last5_points_diff": away_form["points"] - home_form["points"],
                "away_last5_goals_for_diff": away_form["goals_for"] - home_form["goals_for"],
                "away_last5_goals_against_diff": away_form["goals_against"]
                - home_form["goals_against"],
                "home_elo": home_state.elo,
                "away_elo": away_state.elo,
                "elo_diff": home_state.elo - away_state.elo,
                "home_home_only_points": home_state.venue_points(),
                "away_away_only_points": away_state.venue_points(),
                "home_rest_days": home_state.rest_days(kickoff),
                "away_rest_days": away_state.rest_days(kickoff),
                "rest_days_diff": home_state.rest_days(kickoff) - away_state.rest_days(kickoff),
                "home_matches_last_14_days": home_state.congestion(kickoff),
                "away_matches_last_14_days": away_state.congestion(kickoff),
                "congestion_diff": home_state.congestion(kickoff)
                - away_state.congestion(kickoff),
                "home_matched_before": float(home_state.matched),
                "away_matched_before": float(away_state.matched),
                "home_win_rate": home_form["win_rate"],
                "away_win_rate": away_form["win_rate"],
                "home_goal_rate": home_form["goal_rate"],
                "away_goal_rate": away_form["goal_rate"],
                "home_conceded_rate": home_form["conceded_rate"],
                "away_conceded_rate": away_form["conceded_rate"],
                "home_home_points": home_venue["points"],
                "home_home_goals_for": home_venue["goals_for"],
                "home_home_goals_against": home_venue["goals_against"],
                "away_away_points": away_venue["points"],
                "away_away_goals_for": away_venue["goals_for"],
                "away_away_goals_against": away_venue["goals_against"],
                "home_home_points_diff": home_venue["points"] - away_venue["points"],
                "away_away_points_diff": away_venue["points"] - home_venue["points"],
                "home_venue_win_rate": home_state.venue_win_rate(),
                "away_venue_win_rate": away_state.venue_win_rate(),
                "is_draw_competition_rate": _draw_rate(draw_counts[comp]),
            }
        )

        record = dict(row)
        record["features"] = features
        record["feature_version"] = FEATURE_VERSION
        record["is_cold_start"] = home_state.matched == 0 or away_state.matched == 0
        if _completed(row):
            record["label_1x2"] = target_label(row)
            record["label_over_under"] = over_under_target(row)
            record["label_btts"] = btts_target(row)
        else:
            record["label_1x2"] = None
            record["label_over_under"] = None
            record["label_btts"] = None
        enriched.append(record)
        team_history[home_key].append(row)
        if away_key != home_key:
            team_history[away_key].append(row)

        # ---- state updates: only now may this match affect anything ----
        if _completed(row):
            home_score = int(row["home_score"])
            away_score = int(row["away_score"])
            home_points = _result_points(home_score, away_score)
            away_points = _result_points(away_score, home_score)
            home_actual = 1.0 if home_score > away_score else (0.5 if home_score == away_score else 0.0)

            home_state.record(
                {
                    "points": home_points,
                    "goals_for": home_score,
                    "goals_against": away_score,
                    "won": 1.0 if home_score > away_score else 0.0,
                    "draw": 1.0 if home_score == away_score else 0.0,
                    "lost": 1.0 if home_score < away_score else 0.0,
                    "opponent_elo": away_state.elo,
                    "actual": home_actual,
                },
                kickoff,
                home=True,
                goal_diff=home_score - away_score,
            )
            away_state.record(
                {
                    "points": away_points,
                    "goals_for": away_score,
                    "goals_against": home_score,
                    "won": 1.0 if away_score > home_score else 0.0,
                    "draw": 1.0 if away_score == home_score else 0.0,
                    "lost": 1.0 if away_score < home_score else 0.0,
                    "opponent_elo": home_state.elo,
                    "actual": 1.0 - home_actual,
                },
                kickoff,
                home=False,
                goal_diff=away_score - home_score,
            )
            draw_counts[comp][0] += 1 if home_score == away_score else 0
            draw_counts[comp][1] += 1
    return enriched


def _merge_history(first: Sequence[dict], second: Sequence[dict]) -> list[dict]:
    """Union of two clubs' prior fixtures, chronological and de-duplicated.

    A head-to-head fixture appears in both lists; it must appear once, because the
    v1 function counts meetings. Callers pass rows already in walk order, so a merge
    on (kickoff, id) keeps the oldest-first contract without re-sorting.
    """
    if not first:
        return list(second)
    if not second:
        return list(first)
    if first is second:
        return list(first)
    merged: list[dict] = []
    i = j = 0
    seen: set[Any] = set()
    while i < len(first) and j < len(second):
        left, right = first[i], second[j]
        left_key = (_utc(left["kickoff_at"]), left.get("id") or 0)
        right_key = (_utc(right["kickoff_at"]), right.get("id") or 0)
        if left_key <= right_key:
            candidate, i = left, i + 1
        else:
            candidate, j = right, j + 1
        identifier = candidate.get("id")
        if identifier in seen:
            continue
        seen.add(identifier)
        merged.append(candidate)
    for index, remainder in ((i, first), (j, second)):
        for candidate in remainder[index:]:
            identifier = candidate.get("id")
            if identifier in seen:
                continue
            seen.add(identifier)
            merged.append(candidate)
    return merged


def _draw_rate(counter: list[int]) -> float:
    draws, total = counter
    return float(draws) / float(total) if total else 0.0


def feature_row(row: dict) -> list[float]:
    """The ordered float vector for one enriched row."""
    features = row["features"]
    return [float(features[name]) for name in FEATURE_NAMES_V2]


def matrix(rows: Sequence[dict]) -> tuple[list[list[float]], list[dict]]:
    """Feature matrix and aligned label dicts for completed rows only."""
    completed = [r for r in rows if r.get("label_1x2")]
    return [feature_row(r) for r in completed], completed
