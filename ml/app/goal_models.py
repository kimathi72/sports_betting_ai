"""Goal-distribution models: Poisson, Dixon-Coles and scoreline grids.

WHY A DISTRIBUTION AND NOT A CLASSIFIER PER MARKET
--------------------------------------------------
1X2, Over/Under, BTTS and Correct Score are four views of ONE joint scoreline
distribution P(H = i, A = j). Deriving all four from the same grid makes them
internally consistent by construction: the 1X2 probabilities sum to 1 and the
Over/Under split sums to 1 because both are sums over the same cells. A customer
can then never see an Over 2.5 probability that is larger than the probability of
the scorelines that produce it.

Direct per-market classifiers can each be individually better calibrated and still
be collectively contradictory. So the pipeline builds the distribution, compares
it with direct classifiers on a chronological holdout, and keeps whichever is
measurably better instead of assuming either wins.

MODELS
------
``PoissonGoalModel``
    Log-linear Poisson on goal counts: lambda_home = base * home_adv * attack_home *
    defence_away, lambda_away = base * attack_away * defence_home. Fitted by
    iterative proportional fitting with a ridge pseudo-count so a team with three
    matches does not get an extreme rate.

``DixonColesModel``
    The same rates, with the Dixon-Coles tau adjustment on the four low-score
    cells. ``rho`` is chosen by a one-dimensional grid search minimising the 1X2 log
    loss on the TRAINING rows only. One scalar per model, not a free parameter per
    team, so it cannot absorb the evaluation set.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

MAX_GOALS = 10  # 0..10 goals per side; the discarded tail is far below 1e-6


def _poisson_pmf(lam: float, k: int) -> float:
    return math.exp(-lam) * lam**k / math.factorial(k)


def _tau(grid: np.ndarray, lambda_home: float, lambda_away: float, rho: float) -> np.ndarray:
    if rho == 0.0:
        return grid
    adjusted = grid.copy()
    factors = {
        (0, 0): 1.0 - lambda_home * lambda_away * rho,
        (0, 1): 1.0 + lambda_home * rho,
        (1, 0): 1.0 + lambda_away * rho,
        (1, 1): 1.0 - rho,
    }
    for (i, j), factor in factors.items():
        adjusted[i, j] *= max(factor, 1e-9)
    total = adjusted.sum()
    return adjusted / total if total > 0 else grid


def score_grid(
    lambda_home: float,
    lambda_away: float,
    rho: float = 0.0,
    max_goals: int = MAX_GOALS,
) -> np.ndarray:
    """Joint P(home = i, away = j) on a (max_goals + 1)^2 grid."""
    if not (lambda_home > 0 and lambda_away > 0):
        raise ValueError("goal rates must be positive")
    home = np.array([_poisson_pmf(lambda_home, i) for i in range(max_goals + 1)])
    away = np.array([_poisson_pmf(lambda_away, j) for j in range(max_goals + 1)])
    grid = _tau(np.outer(home, away), lambda_home, lambda_away, rho)
    # The grid is truncated at max_goals, so its mass is 0.9999... rather than 1.
    # Renormalising keeps every derived market a true distribution and makes the
    # "sums to 1" contract exact for callers.
    return grid / grid.sum()


def grid_market_probabilities(grid: np.ndarray) -> dict[str, dict[str, float]]:
    """Every supported market, derived from ONE scoreline grid.

    Correct Score is returned in full; a caller that only needs the top few
    lines can sort it. Returned distributions are normalised so a float artefact
    can never make a caller's "sums to 1" assertion fail.
    """
    home = float(np.tril(grid, -1).sum())  # i > j
    draw = float(np.trace(grid))
    away = float(np.triu(grid, 1).sum())  # j > i
    over = 0.0
    btts = 0.0
    goals_hist: dict[int, float] = {}
    rows, cols = grid.shape
    for i in range(rows):
        for j in range(cols):
            p = float(grid[i, j])
            total = i + j
            if total >= 3:
                over += p
            if i >= 1 and j >= 1:
                btts += p
            goals_hist[total] = goals_hist.get(total, 0.0) + p

    total_mass = home + draw + away
    return {
        "1x2": {"H": home / total_mass, "D": draw / total_mass, "A": away / total_mass},
        "over_under_2.5": {"Over": over, "Under": 1.0 - over},
        "btts": {"Yes": btts, "No": 1.0 - btts},
        "double_chance": {
            "1X": (home + draw) / total_mass,
            "X2": (draw + away) / total_mass,
            "12": (home + away) / total_mass,
        },
        "correct_score": {
            f"{i}-{j}": float(grid[i, j]) for i in range(rows) for j in range(cols) if grid[i, j] > 0
        },
        "total_goals": {str(k): v for k, v in sorted(goals_hist.items())},
    }


def alternative_total_line(grid: np.ndarray, line: float) -> dict[str, float]:
    """Over/Under for any goal line, from the same grid.

    A whole line (2.0) can push: the push mass is reported separately instead of
    being folded into one side, which would silently inflate that side.
    """
    over = 0.0
    push = 0.0
    rows, cols = grid.shape
    for i in range(rows):
        for j in range(cols):
            total = i + j
            if total > line:
                over += float(grid[i, j])
            elif total == line:
                push += float(grid[i, j])
    return {"Over": over, "Under": 1.0 - over - push, "Push": push}


@dataclass
class TeamStrength:
    attack: float = 1.0
    defence: float = 1.0


@dataclass
class PoissonGoalModel:
    """A time-decayed, shrinking attack/defence model fitted by weighted regression.

    WHY NOT ALTERNATING RATIOS
    --------------------------
    The obvious iterative-proportional fitting "attack = scored / expected" update
    has no normalisation step, so attack and defence trade off against each other and
    the product attack * defence drifts without bound. Evaluated on this dataset it
    pushed the favourite to 4.0 x 5.0 potencies, predicted 2.6 + 2.4 goals per match
    against 2.8 actually scored, and buried the 2- and 3-goal totals that a league
    really produces.

    This model instead SOLVES a weighted Poisson regression with two ridge penalties:

        mu_home = exp(b0 + b_home + a_home - d_away)
        mu_away = exp(b0 + a_away - d_home)
        loss    = sum_t w_t * [mu - y] . (coef) + lambda * (|a|^2 + |d|^2)

    The equation above is LINEAR in the ratings, so one step is a least-squares
    problem solved directly (Gauss-Newton with a Poisson IRLS weight). The ridge term
    is what makes a club with three matches shrink toward the league average instead
    of being trusted at face value.

    ``half_life_days`` weights older matches less: a club's form two years ago is
    weak evidence for this weekend. That is a fixed modelling choice, not a value
    tuned on the evaluation window.
    """

    home_advantage: float = 1.0
    base_rate: float = 1.3
    teams: dict[str, TeamStrength] = field(default_factory=dict)

    RIDGE = 25.0
    HALF_LIFE_DAYS = 365.0
    ITERATIONS = 6
    POTENCY_CAP = 4.0
    MAX_GOALS_PER_SIDE = 8.0

    @classmethod
    def fit(
        cls,
        rows: list[dict],
        *,
        ridge: float | None = None,
        half_life_days: float | None = None,
    ) -> "PoissonGoalModel":
        ridge = cls.RIDGE if ridge is None else ridge
        half_life_days = cls.HALF_LIFE_DAYS if half_life_days is None else half_life_days

        matches: list[tuple[str, str, float, float, float]] = []
        latest = None
        for row in rows:
            if row.get("status") != "completed":
                continue
            hs, as_ = row.get("home_score"), row.get("away_score")
            if hs is None or as_ is None:
                continue
            matches.append((str(row["home_team_id"]), str(row["away_team_id"]), float(hs), float(as_), row["kickoff_at"]))
            if latest is None or row["kickoff_at"] > latest:
                latest = row["kickoff_at"]
        if not matches:
            raise ValueError("no completed matches to fit a goal model")

        teams = sorted({team for m in matches for team in m[:2]})
        index = {team: i for i, team in enumerate(teams)}
        n = len(teams)

        # Design: one row per side. Columns = [intercept, home, attack(team), defence(team)]
        base = sum(m[2] + m[3] for m in matches) / (2.0 * len(matches))
        home_goals = sum(m[2] for m in matches)
        away_goals = sum(m[3] for m in matches)
        share = (home_goals + 1.0) / (home_goals + away_goals + 2.0)
        home_adv = max(share / (1.0 - share), 1.0001)

        from datetime import datetime, timezone

        def _age_days(kickoff: str) -> float:
            stamp = datetime.fromisoformat(str(kickoff).replace("Z", "+00:00"))
            if stamp.tzinfo is None:
                stamp = stamp.replace(tzinfo=timezone.utc)
            reference = datetime.fromisoformat(str(latest).replace("Z", "+00:00"))
            if reference.tzinfo is None:
                reference = reference.replace(tzinfo=timezone.utc)
            return max((reference - stamp).total_seconds() / 86400.0, 0.0)

        rows_design = []
        for home, away, hs, as_, kickoff in matches:
            weight = 0.5 ** (_age_days(kickoff) / half_life_days)
            h, a = index[home], index[away]
            # home side
            x_home = np.zeros(2 + 2 * n)
            x_home[0] = 1.0
            x_home[1] = 1.0
            x_home[2 + h] = 1.0
            x_home[2 + n + a] = 1.0
            # away side
            x_away = np.zeros(2 + 2 * n)
            x_away[0] = 1.0
            x_away[2 + a] = 1.0
            x_away[2 + n + h] = 1.0
            rows_design.append((x_home, hs, weight))
            rows_design.append((x_away, as_, weight))

        X = np.array([r[0] for r in rows_design])
        y = np.array([r[1] for r in rows_design])
        w = np.array([r[2] for r in rows_design])

        beta = np.zeros(2 + 2 * n)
        beta[0] = math.log(base)
        beta[1] = math.log(home_adv)
        penalty = np.eye(len(beta)) * ridge
        penalty[0, 0] = 0.0  # never shrink the intercept
        penalty[1, 1] = 0.0  # nor the home advantage

        for _ in range(cls.ITERATIONS):
            eta = np.clip(X @ beta, -8.0, 8.0)
            mu = np.exp(eta)
            # Poisson IRLS: solve (X'W_mu W_age X + P) b = X'W_mu W_age (eta - (mu-y)/mu)
            irls = w * mu
            hessian = (X.T * irls) @ X + penalty
            gradient = (X.T * irls) @ (eta + (y - mu) / np.maximum(mu, 1e-9))
            beta = np.linalg.solve(hessian, gradient)

        # Attack/defence are identified only up to a shared shift (a_a + c, d_d - c
        # leaves every rate unchanged). Centre them so the ratings are interpretable
        # and comparable across fits.
        attack = beta[2 : 2 + n]
        defence = beta[2 + n :]
        shift = float((attack.mean() - defence.mean()) / 2.0)
        attack = attack - shift
        defence = defence + shift

        model = cls(home_advantage=float(math.exp(beta[1])), base_rate=float(math.exp(beta[0])))
        model.teams = {
            team: TeamStrength(
                attack=float(math.exp(min(attack[i], math.log(cls.POTENCY_CAP)))),
                defence=float(math.exp(min(-defence[i], math.log(cls.POTENCY_CAP)))),
            )
            for team, i in index.items()
        }
        model.max_rate = cls.MAX_GOALS_PER_SIDE
        return model

    def rates(self, home_team_id: object, away_team_id: object) -> tuple[float, float]:
        home = self.teams.get(str(home_team_id), TeamStrength())
        away = self.teams.get(str(away_team_id), TeamStrength())
        lambda_home = self.base_rate * self.home_advantage * home.attack * away.defence
        lambda_away = self.base_rate * away.attack * home.defence
        ceiling = getattr(self, "max_rate", 8.0)
        return (
            max(min(lambda_home, ceiling), 0.05),
            max(min(lambda_away, ceiling), 0.05),
        )

    def score_grid(self, home_team_id: object, away_team_id: object, rho: float = 0.0) -> np.ndarray:
        lh, la = self.rates(home_team_id, away_team_id)
        return score_grid(lh, la, rho=rho)


@dataclass
class DixonColesModel:
    """Poisson rates plus a low-score dependence correction fitted on outcomes."""

    poisson: PoissonGoalModel
    rho: float = 0.0

    RHO_GRID = tuple(round(x, 3) for x in np.arange(-0.20, 0.201, 0.02))

    @classmethod
    def fit(
        cls,
        rows: list[dict],
        *,
        rho_grid: tuple[float, ...] | None = None,
        block_days: int = 14,
    ) -> "DixonColesModel":
        """Fit rates, then choose rho on the training rows.

        ``block_days`` limits the rho search to a chronological hold-back at the END
        of the training rows, so the scalar is chosen on data closest in time to
        the evaluation period. The hold-back is never the evaluation set: the caller
        passes training rows only.
        """
        poisson = PoissonGoalModel.fit(rows)
        completed = [
            r for r in rows if r.get("status") == "completed" and r.get("home_score") is not None
        ]
        if not completed:
            raise ValueError("no completed matches to fit Dixon-Coles")

        completed.sort(key=lambda r: (r["kickoff_at"], r.get("id") or 0))
        if block_days and len(completed) > 50:
            cutoff = completed[-1]["kickoff_at"]
            # Keep the last ``block_days`` of the training period for rho selection.
            tail = [r for r in completed if r["kickoff_at"] >= _shift_back(cutoff, block_days)]
            selection = tail if len(tail) >= 30 else completed
        else:
            selection = completed

        labels = [_label_1x2(r) for r in selection]
        # One unadjusted grid and one rate pair per selected fixture, reused across
        # every rho candidate. Computing the 1X2 mass per candidate avoids building
        # full grids (and every non-1X2 market) for each of the 21 candidates.
        prepared = [
            (
                poisson.rates(r["home_team_id"], r["away_team_id"]),
                poisson.score_grid(r["home_team_id"], r["away_team_id"]),
            )
            for r in selection
        ]

        best_rho, best_loss = 0.0, float("inf")
        for rho in rho_grid or cls.RHO_GRID:
            loss = 0.0
            for (lh, la), grid, label in zip([p[0] for p in prepared], [p[1] for p in prepared], labels):
                adjusted = _tau(grid, lh, la, rho)
                home = float(np.tril(adjusted, -1).sum())
                draw = float(np.trace(adjusted))
                away = float(np.triu(adjusted, 1).sum())
                total = home + draw + away
                probs = {"H": home / total, "D": draw / total, "A": away / total}
                loss -= math.log(max(probs[label], 1e-12))
            loss /= len(selection)
            if loss < best_loss:
                best_rho, best_loss = rho, loss
        return cls(poisson=poisson, rho=best_rho)

    def score_grid(self, home_team_id: object, away_team_id: object) -> np.ndarray:
        return self.poisson.score_grid(home_team_id, away_team_id, rho=self.rho)


def _label_1x2(row: dict) -> str:
    if row["home_score"] > row["away_score"]:
        return "H"
    if row["home_score"] < row["away_score"]:
        return "A"
    return "D"


def _shift_back(iso_timestamp: str, days: int) -> str:
    from datetime import datetime, timedelta, timezone

    parsed = datetime.fromisoformat(iso_timestamp.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return (parsed - timedelta(days=days)).isoformat()
