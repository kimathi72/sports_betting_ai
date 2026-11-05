"""Probability calibration — infrastructure only.

This module defines the calibration protocol and the metric machinery. Nothing here
is wired into the serving path, and no production calibrator is fitted or published.

THE RULE THAT MATTERS
---------------------
A calibrator is a model. Fitting it on the rows you then score it on will always look
excellent and mean nothing. `CalibrationStudy` therefore refuses to proceed unless the
fit and assessment partitions are disjoint, checked against the spent manifest rather
than trusted from the caller.

METHODS
-------
* `identity`  — no calibration; the baseline every method must beat.
* `platt`     — sigmoid, 2 parameters, safe at small n.
* `isotonic`  — monotone step function, flexible but needs many observations per bin.

Neither is assumed superior. `compare()` fits each on the fit partition and scores all
of them on the assessment partition, so the choice is evidence-led.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable, Mapping, Sequence

import numpy as np

from app.eval_protocol import (
    CALIBRATION_ASSESSMENT,
    CALIBRATION_FIT,
    PartitionError,
    SpentManifest,
)

CALIBRATION_SCHEMA_VERSION = 1


# --------------------------------------------------------------------------- metrics


def log_loss(probabilities: Sequence[float], outcomes: Sequence[int]) -> float:
    """Mean negative log likelihood of the observed class.

    `probabilities` is p(class = 1) for binary problems. Clipped to [1e-15, 1-1e-15]
    so a confidently wrong prediction produces a large finite penalty rather than an
    infinity that poisons a mean.
    """
    p = np.clip(np.asarray(probabilities, dtype=float), 1e-15, 1 - 1e-15)
    y = np.asarray(outcomes, dtype=float)
    return float(-np.mean(y * np.log(p) + (1 - y) * np.log(1 - p)))


def brier_score(probabilities: Sequence[float], outcomes: Sequence[int]) -> float:
    """Mean squared error between probability and outcome. Range [0, 1]."""
    p = np.asarray(probabilities, dtype=float)
    y = np.asarray(outcomes, dtype=float)
    return float(np.mean((p - y) ** 2))


def expected_calibration_error(
    probabilities: Sequence[float],
    outcomes: Sequence[int],
    bins: int = 10,
) -> float:
    """Weighted gap between predicted probability and observed frequency.

    Equal-width bins on [0, 1]. ECE alone is not sufficient — it is sensitive to the
    binning — so reliability tables are reported alongside it.
    """
    p = np.asarray(probabilities, dtype=float)
    y = np.asarray(outcomes, dtype=float)
    if p.size == 0:
        raise ValueError("ECE needs at least one observation")

    edges = np.linspace(0.0, 1.0, bins + 1)
    total = 0.0
    for low, high in zip(edges[:-1], edges[1:]):
        mask = (p >= low) & (p < high if high < 1.0 else p <= high)
        if not mask.any():
            continue
        gap = abs(p[mask].mean() - y[mask].mean())
        total += gap * mask.sum() / p.size
    return float(total)


def reliability_table(
    probabilities: Sequence[float], outcomes: Sequence[int], bins: int = 10
) -> list[dict[str, Any]]:
    """Per-bin count, mean predicted probability and observed frequency."""
    p = np.asarray(probabilities, dtype=float)
    y = np.asarray(outcomes, dtype=float)
    edges = np.linspace(0.0, 1.0, bins + 1)

    table: list[dict[str, Any]] = []
    for low, high in zip(edges[:-1], edges[1:]):
        mask = (p >= low) & (p < high if high < 1.0 else p <= high)
        count = int(mask.sum())
        table.append(
            {
                "bin": f"{low:.1f}-{high:.1f}",
                "count": count,
                "mean_probability": float(p[mask].mean()) if count else None,
                "observed_frequency": float(y[mask].mean()) if count else None,
            }
        )
    return table


# --------------------------------------------------------------------------- calibrators


class IdentityCalibrator:
    """No calibration. The control every method must beat."""

    name = "identity"

    def fit(self, probabilities: Sequence[float], outcomes: Sequence[int]) -> "IdentityCalibrator":
        return self

    def transform(self, probabilities: Sequence[float]) -> np.ndarray:
        return np.clip(np.asarray(probabilities, dtype=float), 0.0, 1.0)

    def to_dict(self) -> dict[str, Any]:
        return {"method": self.name}


class PlattCalibrator:
    """Sigmoid calibration: p' = 1 / (1 + exp(-(a * logit(p) + b))).

    Fitted by a small Newton/gradient loop in pure numpy, so the ML image needs no
    extra dependency and the fit is inspectable. Two parameters make it stable on the
    sample sizes this project has.
    """

    name = "platt"

    def __init__(self, iterations: int = 100, learning_rate: float = 0.1):
        self.a = 1.0
        self.b = 0.0
        self.iterations = iterations
        self.learning_rate = learning_rate

    @staticmethod
    def _logit(p: np.ndarray) -> np.ndarray:
        p = np.clip(p, 1e-6, 1 - 1e-6)
        return np.log(p / (1 - p))

    def fit(self, probabilities: Sequence[float], outcomes: Sequence[int]) -> "PlattCalibrator":
        x = self._logit(np.asarray(probabilities, dtype=float))
        y = np.asarray(outcomes, dtype=float)
        a, b = 1.0, 0.0

        for _ in range(self.iterations):
            z = a * x + b
            p = 1.0 / (1.0 + np.exp(-z))
            error = p - y
            grad_a = float(np.mean(error * x))
            grad_b = float(np.mean(error))
            a -= self.learning_rate * grad_a
            b -= self.learning_rate * grad_b

        self.a, self.b = float(a), float(b)
        return self

    def transform(self, probabilities: Sequence[float]) -> np.ndarray:
        x = self._logit(np.asarray(probabilities, dtype=float))
        return 1.0 / (1.0 + np.exp(-(self.a * x + self.b)))

    def to_dict(self) -> dict[str, Any]:
        return {"method": self.name, "a": self.a, "b": self.b}


class IsotonicCalibrator:
    """Isotonic regression by pool-adjacent-violators.

    Assumes monotonicity of the true probability in the predicted probability. With
    few observations it overfits into step functions, which is why it is compared
    against Platt rather than assumed better.
    """

    name = "isotonic"

    def __init__(self):
        self._x: np.ndarray = np.array([])
        self._y: np.ndarray = np.array([])

    def fit(self, probabilities: Sequence[float], outcomes: Sequence[int]) -> "IsotonicCalibrator":
        p = np.asarray(probabilities, dtype=float)
        y = np.asarray(outcomes, dtype=float)
        order = np.argsort(p)
        x_sorted = p[order]
        y_sorted = y[order]

        # Pool adjacent violators.
        values: list[float] = []
        weights: list[int] = []
        for value in y_sorted:
            values.append(float(value))
            weights.append(1)
            while len(values) > 1 and values[-2] > values[-1]:
                v2, w2 = values.pop(), weights.pop()
                v1, w1 = values.pop(), weights.pop()
                values.append((v1 * w1 + v2 * w2) / (w1 + w2))
                weights.append(w1 + w2)

        expanded: list[float] = []
        for value, weight in zip(values, weights):
            expanded.extend([value] * weight)

        self._x, self._y = x_sorted, np.asarray(expanded, dtype=float)
        return self

    def transform(self, probabilities: Sequence[float]) -> np.ndarray:
        if self._x.size == 0:
            return np.clip(np.asarray(probabilities, dtype=float), 0.0, 1.0)
        return np.interp(np.asarray(probabilities, dtype=float), self._x, self._y)

    def to_dict(self) -> dict[str, Any]:
        return {
            "method": self.name,
            "knots_x": [float(v) for v in self._x],
            "knots_y": [float(v) for v in self._y],
        }


CALIBRATORS: dict[str, Callable[[], Any]] = {
    "identity": IdentityCalibrator,
    "platt": PlattCalibrator,
    "isotonic": IsotonicCalibrator,
}


def make_calibrator(method: str):
    if method not in CALIBRATORS:
        raise ValueError(
            f"unknown calibration method {method!r}; known: {sorted(CALIBRATORS)}"
        )
    return CALIBRATORS[method]()


# --------------------------------------------------------------------------- study


@dataclass
class CalibrationResult:
    method: str
    n_fit: int
    n_assess: int
    log_loss: float
    brier_score: float
    ece: float
    reliability: list[dict[str, Any]] = field(default_factory=list)
    parameters: dict[str, Any] = field(default_factory=dict)


@dataclass
class CalibrationStudy:
    """Fit on one partition, score on a disjoint one. Nothing is persisted here.

    `manifest` is required, not optional: the disjointness check is the entire
    guarantee this module offers, and a caller must not be able to skip it.
    """

    manifest: SpentManifest
    fit_ids: Sequence[int]
    assess_ids: Sequence[int]

    def __post_init__(self) -> None:
        overlap = set(self.fit_ids) & set(self.assess_ids)
        if overlap:
            raise PartitionError(
                "calibration fit and assessment share observations "
                f"({', '.join(str(m) for m in sorted(overlap)[:10])}); "
                "the assessment would not be out of sample"
            )
        if not self.fit_ids:
            raise PartitionError("no calibration-fit observations supplied")
        if not self.assess_ids:
            raise PartitionError("no calibration-assessment observations supplied")

    def compare(
        self,
        *,
        fit_probabilities: Sequence[float],
        fit_outcomes: Sequence[int],
        assess_probabilities: Sequence[float],
        assess_outcomes: Sequence[int],
        methods: Sequence[str] = ("identity", "platt", "isotonic"),
        bins: int = 10,
    ) -> list[CalibrationResult]:
        if len(fit_probabilities) != len(fit_outcomes):
            raise ValueError("fit probabilities and outcomes differ in length")
        if len(assess_probabilities) != len(assess_outcomes):
            raise ValueError("assessment probabilities and outcomes differ in length")
        if len(fit_probabilities) != len(self.fit_ids):
            raise ValueError("fit observations do not match the declared fit ids")
        if len(assess_probabilities) != len(self.assess_ids):
            raise ValueError("assessment observations do not match the declared assess ids")

        results: list[CalibrationResult] = []
        for method in methods:
            calibrator = make_calibrator(method)
            calibrator.fit(fit_probabilities, fit_outcomes)
            calibrated = calibrator.transform(assess_probabilities)

            results.append(
                CalibrationResult(
                    method=method,
                    n_fit=len(self.fit_ids),
                    n_assess=len(self.assess_ids),
                    log_loss=log_loss(calibrated, assess_outcomes),
                    brier_score=brier_score(calibrated, assess_outcomes),
                    ece=expected_calibration_error(calibrated, assess_outcomes, bins=bins),
                    reliability=reliability_table(calibrated, assess_outcomes, bins=bins),
                    parameters=calibrator.to_dict(),
                )
            )
        return results

    def metadata(self, results: Sequence[CalibrationResult], *, base_model: str,
                 feature_version: str, fit_range: str, assess_range: str,
                 artifact_sha256: str) -> dict[str, Any]:
        """Versioned calibration metadata, ready to persist beside an artifact.

        Written as a sibling document; it never modifies the model artifact itself.
        """
        return {
            "schema_version": CALIBRATION_SCHEMA_VERSION,
            "base_model": base_model,
            "feature_version": feature_version,
            "calibration_fit_range": fit_range,
            "calibration_assessment_range": assess_range,
            "artifact_sha256": artifact_sha256,
            "n_fit": len(self.fit_ids),
            "n_assess": len(self.assess_ids),
            "results": [
                {
                    "method": r.method,
                    "log_loss": r.log_loss,
                    "brier_score": r.brier_score,
                    "ece": r.ece,
                    "parameters": r.parameters,
                }
                for r in results
            ],
        }
