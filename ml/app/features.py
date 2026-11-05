"""Pre-kickoff feature engineering for the 1X2 prediction model.

Every feature for a candidate match is computed from information available
*before* that match's kickoff. Target leakage is structurally prevented by
only ever reading the supplied history and by filtering it to matches that
finished before the candidate kickoff. No feature is derived from the
candidate match itself (scores, result) or from any future match.

The feature vector is a flat float vector in the documented ``FEATURE_NAMES``
order so it can be serialised to JSON and fed straight into the classifier.
"""
from __future__ import annotations

from datetime import datetime, timezone

from ml.app.model_store import FEATURE_NAMES  # re-exported canonical list

HOME_WINDOW = 5
AWAY_WINDOW = 5
H2H_WINDOW = 5


class FeatureError(ValueError):
    """Raised when a match or its history cannot yield a valid feature vector."""


def _utc(value: datetime | str | None) -> datetime:
    """Normalise a kickoff timestamp to a timezone-aware UTC datetime.

    Accepts:
    - ISO 8601 strings ending in ``Z`` (Rails returns these, e.g.
      ``"2020-08-01T15:00:00Z"``).
    - ISO 8601 strings with explicit ``+hh:mm`` or ``-hh:mm`` offsets.
    - Existing timezone-aware Python datetimes.
    - Naive Python datetimes, assumed to be UTC.

    Raises FeatureError for None, empty strings, or malformed timestamps.
    """
    if value is None:
        raise FeatureError("kickoff_at is required to compute features")
    if isinstance(value, str):
        s = value.strip()
        if not s:
            raise FeatureError("kickoff_at is required to compute features")
        try:
            from datetime import datetime as _dt
            # datetime.fromisoformat handles 'Z' in Python 3.11+
            parsed = _dt.fromisoformat(s.replace("Z", "+00:00"))
        except ValueError as exc:
            raise FeatureError(f"malformed kickoff_at timestamp: {value!r}") from exc
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)
    if isinstance(value, datetime):
        if value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)
    raise FeatureError(f"unsupported kickoff_at type: {type(value).__name__}")


def target_label(match: dict) -> str:
    """Return the 1X2 label of a completed match: H, D or A."""
    if match.get("status") != "completed":
        raise FeatureError("target_label is only available for completed matches")
    if match.get("home_score") is None or match.get("away_score") is None:
        raise FeatureError("completed match must carry both scores")
    if match["home_score"] > match["away_score"]:
        return "H"
    if match["home_score"] < match["away_score"]:
        return "A"
    return "D"


def over_under_target(match: dict) -> str:
    """Return the Over/Under 2.5 label of a completed match: Over or Under."""
    if match.get("status") != "completed":
        raise FeatureError("over_under_target is only available for completed matches")
    if match.get("home_score") is None or match.get("away_score") is None:
        raise FeatureError("completed match must carry both scores")
    total_goals = match["home_score"] + match["away_score"]
    return "Over" if total_goals >= 3 else "Under"


def btts_target(match: dict) -> str:
    """Return the Both Teams to Score label of a completed match: Yes or No."""
    if match.get("status") != "completed":
        raise FeatureError("btts_target is only available for completed matches")
    if match.get("home_score") is None or match.get("away_score") is None:
        raise FeatureError("completed match must carry both scores")
    return "Yes" if match["home_score"] >= 1 and match["away_score"] >= 1 else "No"


def double_chance_probabilities(probs_1x2: dict[str, float]) -> dict[str, float]:
    """Derive Double Chance probabilities from 1X2 probabilities.

    1X = P(H) + P(D)
    X2 = P(D) + P(A)
    12 = P(H) + P(A)

    Args:
        probs_1x2: Dict with keys "H", "D", "A" summing to 1.

    Returns:
        Dict with keys "1X", "X2", "12" summing to 2 (each pair sums to 1).
    """
    h = probs_1x2.get("H", 0.0)
    d = probs_1x2.get("D", 0.0)
    a = probs_1x2.get("A", 0.0)

    return {
        "1X": h + d,
        "X2": d + a,
        "12": h + a,
    }


def _team_results(
    team_id: int,
    history: list[dict],
) -> list[dict]:
    """Return the team's completed results from history, most recent first."""
    results: list[dict] = []
    for m in history:
        if m.get("status") != "completed":
            continue
        home = m.get("home_team_id") == team_id
        away = m.get("away_team_id") == team_id
        if not home and not away:
            continue
        if home:
            team_score = m.get("home_score") or 0
            opp_score = m.get("away_score") or 0
        else:
            team_score = m.get("away_score") or 0
            opp_score = m.get("home_score") or 0
        results.append(
            {
                "kickoff_at": m["kickoff_at"],
                "goals_for": float(team_score),
                "goals_against": float(opp_score),
                "points": float(
                    3.0 if team_score > opp_score else (1.0 if team_score == opp_score else 0.0)
                ),
                "won": float(1.0 if team_score > opp_score else 0.0),
                "draw": float(1.0 if team_score == opp_score else 0.0),
                "lost": float(1.0 if team_score < opp_score else 0.0),
            }
        )
    # History arrives oldest-first, so reversing it is newest-first. Sorting on the
    # timestamp gave the same answer but called ``_utc`` on every row, which turned
    # feature computation over a full history into the slowest step of the
    # pipeline; the ordering of the input is already part of this module's
    # contract (see ``compute_match_features``).
    results.reverse()
    return results


def compute_match_features(match: dict, history: list[dict]) -> dict[str, float]:
    """Compute the pre-kickoff feature vector for a candidate match.

    ``history`` must contain only prior matches, already ordered
    chronologically (oldest first) and restricted to matches that ended before
    this match kicked off. The function defensively filters anything that
    arrives late or after kickoff so no caller can leak a future or same-kickoff
    result into the vector.
    """
    kickoff = _utc(match.get("kickoff_at"))
    home_id = match.get("home_team_id")
    away_id = match.get("away_team_id")
    if home_id is None:
        raise FeatureError("home_team_id is required to compute features")
    if away_id is None:
        raise FeatureError("away_team_id is required to compute features")

    past: list[dict] = []
    # One pass, newest-first, stopping at the first row that is not strictly
    # earlier. The input is documented as oldest-first, so walking it backwards
    # gives the same newest-first ``past`` list as sorting the whole history while
    # avoiding an O(n log n) sort per fixture (40k fixtures x a growing history was
    # hours of pure sorting). The sort is kept for a caller that ignores the
    # oldest-first contract only when the input is obviously unordered — which is
    # detected once, from the first and last kickoff, not per row.
    source = list(history or [])
    if len(source) > 1:
        first = _utc(source[0].get("kickoff_at"))
        last = _utc(source[-1].get("kickoff_at"))
        if last < first:
            source.sort(key=lambda m: (_utc(m.get("kickoff_at")), m.get("id") or 0))
    for m in reversed(source):
        m_kickoff = _utc(m.get("kickoff_at"))
        if m_kickoff >= kickoff:
            continue
        if m.get("status") != "completed":
            continue
        if m.get("home_score") is None or m.get("away_score") is None:
            continue
        past.append(m)
    # past is now newest-first. Rows at or after this kickoff are excluded above, so
    # no downstream step needs to re-check the cutoff.

    home_results = _team_results(home_id, past)[:HOME_WINDOW]
    away_results = _team_results(away_id, past)[:AWAY_WINDOW]

    home_points = sum(r["points"] for r in home_results)
    home_gf = sum(r["goals_for"] for r in home_results)
    home_ga = sum(r["goals_against"] for r in home_results)
    home_won = sum(r["won"] for r in home_results)
    home_drawn = sum(r["draw"] for r in home_results)
    home_lost = sum(r["lost"] for r in home_results)

    away_points = sum(r["points"] for r in away_results)
    away_gf = sum(r["goals_for"] for r in away_results)
    away_ga = sum(r["goals_against"] for r in away_results)
    away_won = sum(r["won"] for r in away_results)
    away_drawn = sum(r["draw"] for r in away_results)
    away_lost = sum(r["lost"] for r in away_results)

    # Head-to-head: meetings between the two teams before this kickoff. ``past`` is
    # already chronological (newest first) and already excludes any row at or after
    # this kickoff, so no second filter or sort is needed — that second pass was
    # costing an ``_utc`` parse per row per fixture on a 40k-match dataset.
    h2h_recent = [
        m
        for m in past
        if m.get("home_team_id") in (home_id, away_id)
        and m.get("away_team_id") in (home_id, away_id)
    ][:H2H_WINDOW]

    h2h_home_wins = 0.0
    h2h_draws = 0.0
    h2h_away_wins = 0.0
    for m in h2h_recent:
        if m["home_team_id"] == home_id and m["away_team_id"] == away_id:
            if m["home_score"] > m["away_score"]:
                h2h_home_wins += 1
            elif m["home_score"] < m["away_score"]:
                h2h_away_wins += 1
            else:
                h2h_draws += 1
        elif m["home_team_id"] == away_id and m["away_team_id"] == home_id:
            # home_id is the away side in this fixture
            if m["away_score"] > m["home_score"]:
                h2h_home_wins += 1
            elif m["away_score"] < m["home_score"]:
                h2h_away_wins += 1
            else:
                h2h_draws += 1

    return {
        "home_last5_points": float(home_points),
        "home_last5_goals_for": float(home_gf),
        "home_last5_goals_against": float(home_ga),
        "home_last5_wins": float(home_won),
        "home_last5_draws": float(home_drawn),
        "home_last5_losses": float(home_lost),
        "home_matches_played": float(len(home_results)),
        "away_last5_points": float(away_points),
        "away_last5_goals_for": float(away_gf),
        "away_last5_goals_against": float(away_ga),
        "away_last5_wins": float(away_won),
        "away_last5_draws": float(away_drawn),
        "away_last5_losses": float(away_lost),
        "away_matches_played": float(len(away_results)),
        "h2h_home_wins": float(h2h_home_wins),
        "h2h_draws": float(h2h_draws),
        "h2h_away_wins": float(h2h_away_wins),
    }