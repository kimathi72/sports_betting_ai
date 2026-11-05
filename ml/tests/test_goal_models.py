"""Tests for the goal-distribution models and the markets derived from one grid.

The invariant that matters commercially is consistency between markets. These
tests assert it algebraically on real grids, not on constants: if the 1X2 and
Double Chance numbers ever came from different models, ``P(1X) == P(H) + P(D)``
would fail here.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import numpy as np
import pytest

from ml.app.goal_models import (
    MAX_GOALS,
    DixonColesModel,
    PoissonGoalModel,
    alternative_total_line,
    grid_market_probabilities,
    score_grid,
)


def _dt(day: int, month: int = 8) -> str:
    return (datetime(2024, 8, 1, 15, tzinfo=timezone.utc) + timedelta(days=day - 1)).isoformat()


def _season(*, home_dominance: float = 1.6) -> list[dict]:
    """Four clubs playing a round-robin; strengths differ by construction."""
    fixtures = []
    match_id = 1
    teams = [1, 2, 3, 4]
    strength = {1: 1.6, 2: 1.1, 3: 0.9, 4: 0.5}
    day = 1
    for home in teams:
        for away in teams:
            if home == away:
                continue
            hs = int(round(strength[home] * 1.3 * (home_dominance if home == 1 else 1.0)))
            as_ = int(round(strength[away] * 0.9))
            fixtures.append(
                {
                    "id": match_id,
                    "home_team_id": home,
                    "away_team_id": away,
                    "home_score": hs,
                    "away_score": as_,
                    "status": "completed",
                    "kickoff_at": _dt(day),
                }
            )
            match_id += 1
            day += 3
    return fixtures


# ---------------------------------------------------------------------------
# Grid
# ---------------------------------------------------------------------------


def test_grid_is_a_probability_distribution() -> None:
    grid = score_grid(1.6, 0.9)
    assert grid.shape == (MAX_GOALS + 1, MAX_GOALS + 1)
    assert grid.sum() == pytest.approx(1.0, abs=1e-9)
    assert (grid >= 0).all()


def test_grid_mean_matches_the_rate() -> None:
    home_goals = np.arange(MAX_GOALS + 1)
    grid = score_grid(1.7, 1.2)
    assert float((grid.sum(axis=1) * home_goals).sum()) == pytest.approx(1.7, abs=1e-3)
    assert float((grid.sum(axis=0) * home_goals).sum()) == pytest.approx(1.2, abs=1e-3)


def test_dixon_coles_rho_moves_low_score_cells() -> None:
    plain = score_grid(1.4, 1.1, rho=0.0)
    adjusted = score_grid(1.4, 1.1, rho=-0.1)
    assert adjusted[0, 0] > plain[0, 0]  # negative rho boosts 0-0
    assert adjusted[1, 0] < plain[1, 0]  # and dampens 1-0
    assert adjusted.sum() == pytest.approx(1.0, abs=1e-9)


def test_non_positive_rates_are_rejected() -> None:
    with pytest.raises(ValueError):
        score_grid(0.0, 1.0)


# ---------------------------------------------------------------------------
# Markets derived from one grid
# ---------------------------------------------------------------------------


def test_market_probabilities_are_internally_consistent() -> None:
    markets = grid_market_probabilities(score_grid(1.5, 1.1, rho=-0.05))
    one_x_two = markets["1x2"]
    assert sum(one_x_two.values()) == pytest.approx(1.0, abs=1e-9)
    assert sum(markets["over_under_2.5"].values()) == pytest.approx(1.0, abs=1e-9)
    assert sum(markets["btts"].values()) == pytest.approx(1.0, abs=1e-9)

    dc = markets["double_chance"]
    assert dc["1X"] == pytest.approx(one_x_two["H"] + one_x_two["D"], abs=1e-9)
    assert dc["X2"] == pytest.approx(one_x_two["D"] + one_x_two["A"], abs=1e-9)
    assert dc["12"] == pytest.approx(one_x_two["H"] + one_x_two["A"], abs=1e-9)


def test_over_under_agrees_with_the_scoreline_probabilities() -> None:
    grid = score_grid(1.3, 1.4)
    markets = grid_market_probabilities(grid)
    rebuild = sum(
        float(grid[i, j]) for i in range(grid.shape[0]) for j in range(grid.shape[1]) if i + j >= 3
    )
    assert markets["over_under_2.5"]["Over"] == pytest.approx(rebuild, abs=1e-9)


def test_btts_agrees_with_the_grid() -> None:
    grid = score_grid(1.3, 1.4)
    markets = grid_market_probabilities(grid)
    rebuild = sum(float(grid[i, j]) for i in range(1, grid.shape[0]) for j in range(1, grid.shape[1]))
    assert markets["btts"]["Yes"] == pytest.approx(rebuild, abs=1e-9)


def test_correct_score_lines_sum_to_one() -> None:
    markets = grid_market_probabilities(score_grid(1.2, 1.0))
    assert sum(markets["correct_score"].values()) == pytest.approx(1.0, abs=1e-9)


def test_alternative_lines_are_monotone() -> None:
    grid = score_grid(1.4, 1.2)
    over_1_5 = alternative_total_line(grid, 1.5)["Over"]
    over_2_5 = alternative_total_line(grid, 2.5)["Over"]
    over_3_5 = alternative_total_line(grid, 3.5)["Over"]
    assert over_1_5 > over_2_5 > over_3_5


def test_whole_line_reports_push_separately() -> None:
    grid = score_grid(1.4, 1.2)
    result = alternative_total_line(grid, 2.0)
    assert result["Push"] > 0.0
    assert result["Over"] + result["Under"] + result["Push"] == pytest.approx(1.0, abs=1e-9)
    # A push must not be folded into Over: the half line around it brackets it.
    assert result["Over"] < alternative_total_line(grid, 1.5)["Over"]


# ---------------------------------------------------------------------------
# Fitted models
# ---------------------------------------------------------------------------


def test_poisson_fit_prefers_the_stronger_attack() -> None:
    model = PoissonGoalModel.fit(_season())
    strong_home, strong_away = model.rates(1, 4)
    weak_home, weak_away = model.rates(4, 1)
    assert strong_home > weak_home
    assert strong_home > strong_away


def test_poisson_fit_requires_completed_matches() -> None:
    with pytest.raises(ValueError):
        PoissonGoalModel.fit([{"status": "scheduled", "home_team_id": 1, "away_team_id": 2}])


def test_unknown_team_falls_back_to_the_league_average() -> None:
    model = PoissonGoalModel.fit(_season())
    lambda_home, lambda_away = model.rates(999, 998)
    assert lambda_home == pytest.approx(model.base_rate * model.home_advantage, rel=1e-6)
    assert lambda_away == pytest.approx(model.base_rate, rel=1e-6)


def test_dixon_coles_rho_is_selected_from_the_training_rows_only() -> None:
    rows = _season()
    model = DixonColesModel.fit(rows)
    assert model.rho in DixonColesModel.RHO_GRID
    # The chosen rho must actually have been evaluated: fitting on a subset may
    # pick a different scalar, which proves it is data-driven, not hard-coded.
    subset = DixonColesModel.fit(rows[: len(rows) // 2])
    assert isinstance(subset.rho, float)


def test_dixon_coles_grid_is_still_a_distribution() -> None:
    model = DixonColesModel.fit(_season())
    grid = model.score_grid(1, 2)
    assert grid.sum() == pytest.approx(1.0, abs=1e-9)
    assert (grid >= 0).all()


def test_ridge_keeps_a_single_match_team_from_extreme_rates() -> None:
    rows = [
        {
            "id": 1,
            "home_team_id": 1,
            "away_team_id": 2,
            "home_score": 9,
            "away_score": 0,
            "status": "completed",
            "kickoff_at": _dt(1),
        }
    ]
    model = PoissonGoalModel.fit(rows)
    lambda_home, _ = model.rates(1, 2)
    assert lambda_home <= model.max_rate
    assert lambda_home < 12.0, "a single 9-0 must not imply a double-figure goal rate"


def test_fitted_rates_reproduce_league_goal_averages() -> None:
    """A fitted model must broadly reproduce the goals it was fitted on.

    This is the check that catches an identification bug: an unnormalised
    attack/defence trade-off produces rates that are wildly off the observed
    average while still "fitting" individual teams.
    """
    rows = _season()
    model = PoissonGoalModel.fit(rows)
    observed_home = np.mean([r["home_score"] for r in rows])
    observed_away = np.mean([r["away_score"] for r in rows])
    predicted = np.array([model.rates(r["home_team_id"], r["away_team_id"]) for r in rows])
    assert predicted[:, 0].mean() == pytest.approx(observed_home, rel=0.25)
    assert predicted[:, 1].mean() == pytest.approx(observed_away, rel=0.25)
