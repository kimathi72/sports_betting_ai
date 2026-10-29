"""FastAPI ML service supporting multiple prediction markets.

Supports 1X2, Double Chance, Over/Under 2.5 Goals, and Both Teams to Score.

Canonical contract:
- POST /predict accepts a flat JSON object whose keys are exactly the 17
  pre-kickoff feature names and whose values are finite floats. It returns
  normalized probabilities for the active market, the model version and the
  prediction time.
- GET /health is liveness only; it never touches the model.
- GET /ready reports whether the model artifact is loadable.
- GET /model/status returns model version, trained_at, classes and feature names.
- GET /metrics returns held-out evaluation metrics when present.
- POST /predict/{market} accepts market-specific predictions.

The model is trained separately and persisted to disk. Inference never
retrains. Probabilities are finite, between 0 and 1, and sum to 1.
"""
from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict

from fastapi import FastAPI, HTTPException, Path as PathParam
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict

from ml.app.features import FEATURE_NAMES, double_chance_probabilities
from ml.app.model_store import (
    TRAINED_MARKETS,
    UNKNOWN_MARKET,
    ModelBundle,
    ModelError,
    load_bundle,
    save_bundle,
    get_model_path,
    MARKET_1X2,
    MARKET_DOUBLE_CHANCE,
    MARKET_OVER_UNDER,
    MARKET_BTTS,
)
from ml.app.model import predict_proba, predict_binary_proba, train_baseline, train_binary_classifier
from ml.app.metrics import MetricError, evaluate_predictions, held_out_metrics, binary_evaluate_predictions

# ---------------------------------------------------------------------------
# App & paths
# ---------------------------------------------------------------------------

app = FastAPI(
    title="Sports Betting AI ML",
    version="0.1.0",
    docs_url="/api/v1/ml/docs",
    redoc_url="/api/v1/ml/redoc",
)

MODEL_PATH = os.getenv("ML_MODEL_PATH", "/app/artifacts/model.joblib")
METRICS_PATH = os.getenv("ML_METRICS_PATH", "/app/artifacts/metrics.json")

SUPPORTED_MARKETS = [MARKET_1X2, MARKET_DOUBLE_CHANCE, MARKET_OVER_UNDER, MARKET_BTTS]

# ---------------------------------------------------------------------------
# Request / response schemas
# ---------------------------------------------------------------------------


class PredictRequest(BaseModel):
    """Flat JSON body: exactly the 17 pre-kickoff feature names as floats.

    Extra keys are rejected (422) so a caller cannot silently send a feature
    the model was not trained on. Missing keys are also rejected.
    """

    model_config = ConfigDict(extra="forbid")

    home_last5_points: float
    home_last5_goals_for: float
    home_last5_goals_against: float
    home_last5_wins: float
    home_last5_draws: float
    home_last5_losses: float
    home_matches_played: float
    away_last5_points: float
    away_last5_goals_for: float
    away_last5_goals_against: float
    away_last5_wins: float
    away_last5_draws: float
    away_last5_losses: float
    away_matches_played: float
    h2h_home_wins: float
    h2h_draws: float
    h2h_away_wins: float


class MarketPredictRequest(BaseModel):
    """Market-aware prediction request: features plus explicit market id."""

    model_config = ConfigDict(extra="forbid")

    market: str | None = None
    home_last5_points: float
    home_last5_goals_for: float
    home_last5_goals_against: float
    home_last5_wins: float
    home_last5_draws: float
    home_last5_losses: float
    home_matches_played: float
    away_last5_points: float
    away_last5_goals_for: float
    away_last5_goals_against: float
    away_last5_wins: float
    away_last5_draws: float
    away_last5_losses: float
    away_matches_played: float
    h2h_home_wins: float
    h2h_draws: float
    h2h_away_wins: float


class PredictResponse(BaseModel):
    probabilities: Dict[str, float]
    model_version: str
    predicted_at: str


class ModelStatus(BaseModel):
    model_version: str
    trained_at: str
    classes: list[str]
    feature_names: list[str]
    market: str


class Health(BaseModel):
    status: str = "ok"


# ---------------------------------------------------------------------------
# Model cache
# ---------------------------------------------------------------------------

_artifact_paths: dict[str, Path] = {}


def _artifact_market(market: str) -> str:
    """The market whose artifact actually backs a requested market.

    Derived markets are projected from a trained market and have no artifact of
    their own. Double chance is the only such market: it is P(H)+P(D),
    P(D)+P(A), P(H)+P(A) of the 1X2 distribution, so it MUST be served by the
    1X2 artifact. Asking for a ``double_chance`` artifact is a bug — there is no
    file at that path, and creating one would allow the two markets to disagree.
    """
    return DERIVED_MARKET_SOURCE.get(market, market)


def _get_artifact_path(market: str) -> Path:
    """Return the artifact path for a market.

    Honors test overrides in ``_artifact_paths``; otherwise uses the
    ``ML_MODEL_PATH`` env var for 1X2 and the per-market default path for
    other markets. Derived markets resolve to their source market's artifact.
    """
    backing = _artifact_market(market)
    if backing in _artifact_paths:
        return _artifact_paths[backing]
    if backing == MARKET_1X2:
        return Path(MODEL_PATH)
    return get_model_path(backing)


def set_artifact_path(market: str, path: str | Path) -> None:
    """Override the artifact path for a market (used by tests)."""
    _artifact_paths[market] = Path(path)


_model_caches: dict[str, ModelBundle | None] = {}


# Derived market -> the trained market whose artifact backs it.
DERIVED_MARKET_SOURCE = {MARKET_DOUBLE_CHANCE: MARKET_1X2}

# The 1X2 label space. A binary artifact cannot legitimately claim to be 1X2.
MARKET_1X2_CLASSES = frozenset({"H", "D", "A"})

logger = logging.getLogger(__name__)


def _legacy_mislabelled(market: str, declared: str, classes) -> bool:
    """True when a `1x2` label is provably a default rather than a claim.

    Binary artifacts written before the binary trainers accepted a `market`
    argument defaulted to `1x2`. A two-class model whose classes are not the 1X2
    classes cannot be a 1X2 model, so the label carries no information and the
    classes are the authority. This is a compatibility path for artifacts on
    disk, not a general "ignore the label" escape hatch: the declared market must
    still be `1x2`, the artifact must be binary, and the classes must not be the
    1X2 classes.
    """
    return (
        declared == MARKET_1X2
        and market in TRAINED_MARKETS
        and market != MARKET_1X2
        and len(list(classes)) == 2
        and not set(classes).intersection(MARKET_1X2_CLASSES)
    )


def _load_model(market: str = MARKET_1X2) -> ModelBundle:
    if market not in SUPPORTED_MARKETS:
        raise HTTPException(
            status_code=400,
            detail=f"unsupported market '{market}'. Supported: {SUPPORTED_MARKETS}",
        )
    # A derived market is served by its source market's artifact; the cache is
    # keyed on the ARTIFACT market so the same bundle is not loaded twice.
    market = _artifact_market(market)
    global _model_caches
    if market not in _model_caches:
        _model_caches[market] = None
    if _model_caches[market] is None:
        artifact_path = _get_artifact_path(market)
        try:
            bundle = load_bundle(artifact_path)
        except ModelError as exc:
            raise HTTPException(
                status_code=503,
                detail=f"model for market '{market}' is not available: {exc}",
            )

        # The artifact's own market must agree with what is being served.
        #
        # Two cases are tolerated, both narrow and both reported in the logs so
        # an operator can fix them:
        #   - UNKNOWN_MARKET: an artifact predating market metadata, whose label
        #     classes still identify the market unambiguously.
        #   - LEGACY_1X2_LABEL: artifacts written before the binary trainers
        #     accepted a `market` argument were stamped `1x2`. With two classes
        #     and no 1x2 class present, this cannot be a real 1X2 model (1X2 is
        #     three-class), so the label is provably a default, not a claim.
        #
        # Anything else is refused: a three-class artifact served as BTTS, or a
        # binary artifact whose classes match a DIFFERENT market, is a genuine
        # mismatch and relabelling it would let /model/status report a file that
        # is not the one actually in use.
        declared = bundle.market
        if declared not in (UNKNOWN_MARKET, market) and not _legacy_mislabelled(
            market, declared, bundle.classes
        ):
            raise HTTPException(
                status_code=503,
                detail=(
                    f"model for market '{market}' is not available: the artifact at "
                    f"{artifact_path} declares market '{declared}'. Refusing to serve a "
                    "model under another market's name."
                ),
            )
        if declared != market:
            logger.warning(
                "serving %s from an artifact labelled %r (classes=%s); retrain to "
                "stamp the correct market",
                market,
                declared,
                list(bundle.classes),
            )
        _model_caches[market] = bundle
    return _model_caches[market]


def load_model(market: str = MARKET_1X2) -> None:
    """Public hook to reset the model cache so tests can point at a new path."""
    global _model_caches
    _model_caches[market] = None


# ---------------------------------------------------------------------------
# Liveness / readiness
# ---------------------------------------------------------------------------


@app.get("/health", response_model=Health, tags=["health"])
def health() -> Health:
    return Health(status="ok")


@app.get("/ready", tags=["readiness"])
def ready() -> JSONResponse:
    try:
        _load_model(MARKET_1X2)
        return JSONResponse(
            content={"status": "ready", "checks": {"database": "ok"}},
            status_code=200,
        )
    except HTTPException:
        return JSONResponse(
            content={"status": "not_ready", "checks": {"database": "unavailable"}},
            status_code=503,
        )


# ---------------------------------------------------------------------------
# Model status
# ---------------------------------------------------------------------------


@app.get("/model/status", response_model=ModelStatus, tags=["model"])
def model_status(market: str = MARKET_1X2) -> ModelStatus:
    bundle = _load_model(market)
    return ModelStatus(
        model_version=bundle.model_version,
        trained_at=bundle.trained_at.isoformat(),
        classes=list(bundle.classes),
        feature_names=list(bundle.feature_names),
        market=bundle.market,
    )


# ---------------------------------------------------------------------------
# Predict
# ---------------------------------------------------------------------------


@app.post("/predict", response_model=PredictResponse, tags=["prediction"])
def predict(req: MarketPredictRequest) -> PredictResponse:
    """Market-aware prediction endpoint.

    Accepts an optional ``market`` field plus the 17 pre-kickoff feature names.
    Defaults to the 1X2 market when none is supplied. Returns validated
    probabilities for the requested market.
    """
    market = req.market or MARKET_1X2
    bundle = _load_model(market)
    features_dict = req.model_dump()
    features_dict.pop("market", None)

    if market == MARKET_DOUBLE_CHANCE:
        # Double Chance derives from 1X2 via bundle from 1X2 model
        probs_1x2 = predict_proba(bundle.classifier, features_dict, bundle)
        probs = double_chance_probabilities(probs_1x2)
    else:
        probs = predict_proba(bundle.classifier, features_dict, bundle)

    predicted_at = datetime.now(timezone.utc).isoformat()
    return PredictResponse(
        probabilities=probs,
        model_version=bundle.model_version,
        predicted_at=predicted_at,
    )


@app.post("/predict/{market}", response_model=PredictResponse, tags=["prediction"])
def predict_market(
    market: str,
    req: PredictRequest,
) -> PredictResponse:
    """Market-specific prediction endpoint.

    Accepts a market identifier in the URL path and the 17 pre-kickoff
    feature names in the request body.
    """
    if market not in SUPPORTED_MARKETS:
        raise HTTPException(
            status_code=400,
            detail=f"unsupported market '{market}'. Supported: {SUPPORTED_MARKETS}",
        )
    # Default to 1X2 if market is None or empty
    market = market or MARKET_1X2
    bundle = _load_model(market)
    features_dict = req.model_dump()

    if market == MARKET_DOUBLE_CHANCE:
        probs_1x2 = predict_proba(bundle.classifier, features_dict, bundle)
        probs = double_chance_probabilities(probs_1x2)
    else:
        probs = predict_proba(bundle.classifier, features_dict, bundle)

    predicted_at = datetime.now(timezone.utc).isoformat()
    return PredictResponse(
        probabilities=probs,
        model_version=bundle.model_version,
        predicted_at=predicted_at,
    )


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------


@app.get("/metrics", tags=["metrics"])
def metrics_endpoint(market: str = MARKET_1X2) -> dict[str, float]:
    # Metrics are optional: a 404 is the honest response when no held-out
    # evaluation has been persisted for the requested market.
    from pathlib import Path

    metrics_path = Path(METRICS_PATH)
    if not metrics_path.is_file():
        raise HTTPException(
            status_code=404,
            detail="model metrics not available — no held-out evaluation data present",
        )
    try:
        raw = json.loads(metrics_path.read_text(encoding="utf-8"))
        # If metrics contain a market key, return only that market's metrics
        if "market" in raw and raw["market"] != market:
            raise HTTPException(
                status_code=404,
                detail=f"metrics for market '{market}' are not available",
            )
        return {
            "accuracy": float(raw.get("accuracy", 0.0)),
            "log_loss": float(raw.get("log_loss", 0.0)),
            "brier_score": float(raw.get("brier_score", 0.0)),
        }
    except Exception:
        raise HTTPException(
            status_code=500,
            detail="model metrics file is corrupt",
        )