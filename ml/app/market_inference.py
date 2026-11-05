"""Market-specific inference helpers shared by the API and the training report.

ONE PLACE FOR "GIVEN A ROW, WHAT ARE THE PROBABILITIES"
-------------------------------------------------------
Rails sends a HISTORY, not a pre-computed vector. That is the whole point of the
``POST /predict/from-history/{market}`` endpoint: feature engineering lives in
Python, so the numbers used at inference are the numbers the model was trained on.
Rails previously mirrored the 17 formulas in Ruby — a second implementation that
can silently disagree. This module removes that duplication from the request path.

The scoreline markets share one distribution, so ``over_under_2.5``, ``btts``,
``correct_score`` and ``double_chance`` are guaranteed consistent with ``1x2``:
they are different sums over the same grid.
"""
from __future__ import annotations

from typing import Any, Iterable, Sequence

import numpy as np

from ml.app.features_v2 import FEATURE_NAMES_V2, enrich_history
from ml.app.goal_models import (
    DixonColesModel,
    PoissonGoalModel,
    grid_market_probabilities,
)

# Kept at the top so the JSON encoder never sees a non-finite float coming out of a
# model: a NaN reaching the encoder raises while the RESPONSE is being rendered,
# which turns an input problem into an unexplained server error.
import math as _math

MARKET_1X2 = "1x2"
MARKET_DOUBLE_CHANCE = "double_chance"
MARKET_OVER_UNDER = "over_under_2.5"
MARKET_BTTS = "btts"
MARKET_CORRECT_SCORE = "correct_score"

GRID_MARKETS = (
    MARKET_1X2,
    MARKET_DOUBLE_CHANCE,
    MARKET_OVER_UNDER,
    MARKET_BTTS,
    MARKET_CORRECT_SCORE,
)


class HistoryError(ValueError):
    """Raised when a history payload cannot yield a prediction."""


def _normalise_match(payload: dict) -> dict:
    required = ("id", "kickoff_at", "home_team_id", "away_team_id")
    missing = [key for key in required if payload.get(key) is None]
    if missing:
        raise HistoryError(f"match is missing {', '.join(missing)}")
    return {
        "id": payload["id"],
        "kickoff_at": str(payload["kickoff_at"]),
        "home_team_id": int(payload["home_team_id"]),
        "away_team_id": int(payload["away_team_id"]),
        "home_score": payload.get("home_score"),
        "away_score": payload.get("away_score"),
        "status": payload.get("status") or "scheduled",
        "competition_id": payload.get("competition_id") or 0,
        "season_id": payload.get("season_id"),
    }


def _history_rows(history: Sequence[dict]) -> list[dict]:
    rows = []
    for entry in history or []:
        if entry.get("kickoff_at") is None:
            continue
        rows.append(
            {
                "id": entry.get("id", 0),
                "kickoff_at": str(entry["kickoff_at"]),
                "home_team_id": entry.get("home_team_id"),
                "away_team_id": entry.get("away_team_id"),
                "home_score": entry.get("home_score"),
                "away_score": entry.get("away_score"),
                "status": entry.get("status", "completed"),
                "competition_id": entry.get("competition_id") or 0,
                "season_id": entry.get("season_id"),
            }
        )
    return rows


def feature_vector_for(match: dict, history: Sequence[dict]) -> tuple[dict[str, float], int]:
    """The v2 feature dict for one fixture, from its history.

    The history is enriched together with the fixture and only the fixture's own
    row is read back, which guarantees the fixture was scored by exactly the state
    its history produced — including Elo and congestion, which are path-dependent.
    """
    fixture = _normalise_match(match)
    history_rows = _history_rows(history)
    # The fixture is included so the chronological walk positions it after its
    # history; a same-kickoff history row is excluded by the builder's ordering.
    combined = history_rows + [fixture]
    enriched = enrich_history(combined)
    target = None
    for row in enriched:
        if row["id"] == fixture["id"] and row["kickoff_at"] == fixture["kickoff_at"]:
            target = row
    if target is None:  # pragma: no cover - defensive
        raise HistoryError("the fixture disappeared while computing features")
    return target["features"], len(history_rows)


class _FixturePredictor:
    """The goal distribution plus a per-market classifier pair.

    ``match`` uses the goal grid, which guarantees 1X2/Over-Under/BTTS/Double
    Chance agree. ``classifier`` uses the published per-market classifiers, which
    won the validation comparison; it is what the flat-feature endpoint serves.
    Holding both in one object is what lets a caller choose a source per request
    instead of the service choosing silently.
    """

    def __init__(self, model, classifiers: dict[str, Any], classes: dict[str, list[str]], feature_names: list[str]) -> None:
        self.grid = GoalDistributionPredictor(model)
        self.classifiers = classifiers
        self.classes = classes
        self.feature_names = feature_names

    def markets(self, match: dict, history):
        return self.grid.markets(match, history)

    def market(self, match: dict, history, market: str):
        features, _ = feature_vector_for(match, history)
        if market in self.classifiers:
            distribution = self.classifier_probabilities_for(match, features, market)
            if distribution is not None:
                return distribution
        return self.grid.market(match, history, market)

    def classifier_probabilities_for(self, match: dict, features: dict[str, float], market: str):
        classifier = self.classifiers.get(market)
        if classifier is None:
            return None
        return classifier_probabilities(classifier, self.classes[market], features, self.feature_names)

    def classifier_market(self, match: dict, history, market: str):
        features, _ = feature_vector_for(match, history)
        result = self.classifier_probabilities_for(match, features, market)
        if result is None:
            raise HistoryError(f"no classifier is published for market {market!r}")
        return result


class GoalDistributionPredictor:
    """Serves every grid-derived market from one Dixon-Coles distribution."""

    def __init__(self, model: DixonColesModel | PoissonGoalModel) -> None:
        self.model = model

    def markets(self, match: dict, history: Sequence[dict]) -> dict[str, dict[str, float]]:
        fixture = _normalise_match(match)
        grid = self.model.score_grid(fixture["home_team_id"], fixture["away_team_id"])
        result = grid_market_probabilities(grid)
        # Keep the payload bounded: the top 6 correct-score lines are what a client
        # can act on, and the full grid stays on the server. Ties break on the
        # scoreline so the order is deterministic rather than dict-order dependent.
        top_scores = dict(
            sorted(result["correct_score"].items(), key=lambda item: (-item[1], item[0]))[:6]
        )
        return {
            MARKET_1X2: result["1x2"],
            MARKET_DOUBLE_CHANCE: result["double_chance"],
            MARKET_OVER_UNDER: result["over_under_2.5"],
            MARKET_BTTS: result["btts"],
            MARKET_CORRECT_SCORE: top_scores,
        }

    def market(self, match: dict, history: Sequence[dict], market: str) -> dict[str, float]:
        markets = self.markets(match, history)
        if market not in markets:
            raise HistoryError(f"unsupported market {market!r}")
        return markets[market]


def classifier_probabilities(classifier, classes: Sequence[str], features: dict[str, float], feature_names: Sequence[str]) -> dict[str, float]:
    """Reorder a fitted classifier's output into the canonical class order."""
    vector = np.array([[features[name] for name in feature_names]], dtype=float)
    raw = classifier.predict_proba(vector)[0]
    native = list(getattr(classifier, "classes_", classes))
    ordered = [raw[native.index(label)] for label in classes]
    if not all(_math.isfinite(value) for value in ordered):
        raise HistoryError("model produced a non-finite probability")
    total = float(sum(ordered))
    if total <= 0:
        raise HistoryError("model produced a zero-probability output")
    return {label: value / total for label, value in zip(classes, ordered)}
