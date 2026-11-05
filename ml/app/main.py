"""FastAPI ML service: market-specific predictions from a match history.

ARCHITECTURE (unchanged): Mobile -> Rails API -> this service. Mobile never calls
it directly. Rails owns data and persistence; this service owns features and
models.

TWO REQUEST SHAPES, ONE RULE
----------------------------
* ``POST /predict`` / ``POST /predict/{market}`` accept the 17 flat v1 features.
  This is the original contract and existing clients keep working.
* ``POST /predict/from-history/{market}`` accepts a match plus its history and
  computes the features HERE. It is the preferred path: feature engineering stays
  in one language, so the numbers at inference are the numbers at training time.

MARKET ISOLATION
----------------
A market whose artifact is missing returns 503 with an explicit message. It never
falls back to another market's artifact, and it never returns a fabricated
probability. An unknown market is a 400: it is a caller mistake, not an outage.

DOUBLE CHANCE is not a model. It is P(1X)=P(H)+P(D) etc. from the 1X2
distribution, so the service derives it and refuses to load any artifact claiming
to be double chance.

DERIVED vs TRAINED MARKETS
--------------------------
1x2, over_under_2.5 and btts may each have a trained artifact. correct_score has
no artifact: it is a joint scoreline distribution, served by the goal model
artifact when one is present, and 503 otherwise.
"""
from __future__ import annotations

import json
import logging
import math
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Literal, Sequence

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator

from ml.app.features import FEATURE_NAMES, double_chance_probabilities
from ml.app.features_v2 import FEATURE_NAMES_V2
from ml.app.model_provenance import (
    PROVENANCE_UNAVAILABLE,
    ArtifactProvenance,
    load_freeze,
)
from ml.app.market_inference import (
    GRID_MARKETS,
    _FixturePredictor,
    MARKET_1X2,
    MARKET_BTTS,
    MARKET_CORRECT_SCORE,
    MARKET_DOUBLE_CHANCE,
    MARKET_OVER_UNDER,
    GoalDistributionPredictor,
    HistoryError,
    feature_vector_for,
)
from ml.app.model import predict_proba, train_baseline, train_binary_classifier  # noqa: F401  (public API)
from ml.app.model_store import (
    DERIVED_MARKETS,
    TRAINED_MARKETS,
    UNKNOWN_MARKET,
    ModelBundle,
    ModelError,
    get_model_path,
    load_bundle,
    save_bundle,
)

app = FastAPI(
    title="Sports Betting AI ML",
    version="0.2.0",
    docs_url="/api/v1/ml/docs",
    redoc_url="/api/v1/ml/redoc",
)

MODEL_PATH = os.getenv("ML_MODEL_PATH", "/app/artifacts/model.joblib")
METRICS_PATH = os.getenv("ML_METRICS_PATH", "/app/artifacts/metrics.json")
# The goal model backs correct_score and, when no per-market artifact exists, is
# also a legitimate source for over/under and BTTS — but only if it was trained.
GOAL_MODEL_PATH = os.getenv("ML_GOAL_MODEL_PATH", "/app/artifacts/model_goal_distribution.joblib")

SUPPORTED_MARKETS = [MARKET_1X2, MARKET_DOUBLE_CHANCE, MARKET_OVER_UNDER, MARKET_BTTS, MARKET_CORRECT_SCORE]

DERIVED_MARKET_SOURCE = {MARKET_DOUBLE_CHANCE: MARKET_1X2}

# Markets with no artifact of their own. Correct score is a projection of the
# goal-distribution artifact; it is not fitted as a multiclass classifier.
PROJECTED_MARKETS = {MARKET_DOUBLE_CHANCE, MARKET_CORRECT_SCORE}

CLASSES_1X2 = ("H", "D", "A")

logger = logging.getLogger(__name__)

# Where artifacts live and which frozen generation they are checked against.
# Environment-overridable so a test or a staging mount can point elsewhere without
# changing code.
ARTIFACTS_DIR = os.environ.get("MODEL_ARTIFACTS_DIR", "/app/artifacts")
FREEZE_PATH = os.environ.get("MODEL_FREEZE_PATH", "/app/artifacts/freeze.json")


# ---------------------------------------------------------------------------
# Request / response schemas
# ---------------------------------------------------------------------------


class PredictRequest(BaseModel):
    """Flat JSON body: exactly the 17 v1 pre-kickoff features as floats.

    Non-finite values (NaN, Infinity) are rejected by an explicit validator below.
    ``allow_inf_nan=False`` is NOT used: it makes pydantic raise on the value while
    FastAPI is SERIALISING the validation error, which replaces the intended 422
    with a 500 complaining that NaN is not JSON compliant — the opposite of the
    intent. A field validator rejects the input cleanly and reports which field.
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

    @field_validator("*", mode="after")
    @classmethod
    def _finite(cls, value: float, info) -> float:
        if isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
            raise ValueError(f"{info.field_name} must be a finite number")
        return value


class MatchPayload(BaseModel):
    """The fixture to predict. Scores are accepted but never used as features."""

    model_config = ConfigDict(extra="ignore")

    id: int
    kickoff_at: str
    home_team_id: int
    away_team_id: int
    status: str = "scheduled"
    home_score: float | None = None
    away_score: float | None = None
    competition_id: int | None = None
    season_id: int | None = None


class HistoryMatch(BaseModel):
    model_config = ConfigDict(extra="ignore")

    id: int
    kickoff_at: str
    home_team_id: int
    away_team_id: int
    status: str = "completed"
    home_score: float | None = None
    away_score: float | None = None
    competition_id: int | None = None


class HistoryPredictRequest(BaseModel):
    """Match plus the history Rails already filtered to strictly-earlier matches.

    ``history`` is not trusted blindly: the feature builder re-applies the kickoff
    cutoff, so a server-side filtering bug cannot leak a result into a prediction.
    """

    model_config = ConfigDict(extra="forbid")

    match: MatchPayload
    history: list[HistoryMatch] = Field(default_factory=list)


class PredictResponse(BaseModel):
    market: str
    probabilities: Dict[str, float]
    model_version: str
    predicted_at: str
    feature_version: str | None = None

    # PROVENANCE (additive; existing fields unchanged).
    #
    # `model_freeze_digest` is the identity of the frozen generation that actually
    # produced these probabilities. It is present ONLY when the loaded artifact's
    # bytes match the freeze record. When verification fails it is None and
    # `provenance_status` says why — an honest absent value rather than a constant
    # that would falsely attribute the prediction to a frozen model.
    model_freeze_digest: str | None = None
    artifact_sha256: str | None = None
    provenance_status: str = "unavailable"


class ModelStatus(BaseModel):
    market: str
    model_version: str
    trained_at: str
    classes: list[str]
    feature_names: list[str]


class Health(BaseModel):
    status: str = "ok"


# ---------------------------------------------------------------------------
# Artifact resolution
# ---------------------------------------------------------------------------

_artifact_paths: dict[str, Path] = {}
# Artifacts directory, overridable so a test (or a side-by-side deployment) can
# point the whole service at its own models without touching every market.
_artifact_dir: str | None = None


def check_market(market: str) -> str:
    """400 for anything that is not a supported market."""
    if market not in SUPPORTED_MARKETS:
        raise HTTPException(
            status_code=400,
            detail=(
                f"unsupported market '{market}'. Supported markets: "
                f"{', '.join(SUPPORTED_MARKETS)}"
            ),
        )
    return market


def _artifact_market(market: str) -> str:
    """The TRAINED market whose artifact actually backs a requested market.

    NO CROSS-MARKET FALLBACK. Over/Under and BTTS each require their own published
    artifact. Falling back to the goal distribution would answer those markets with
    a model that lost the validation comparison, and — worse — would make an
    entirely missing artifact look healthy. That is precisely the "one generic
    artifact serves every market" failure this service was rebuilt to remove.
    """
    return DERIVED_MARKET_SOURCE.get(market, market)


def _default_market_path(market: str) -> str:
    if _artifact_dir is not None:
        return str(Path(_artifact_dir) / f"model_{market}.joblib")
    return str(get_model_path(market))


def _artifact_path(market: str) -> Path:
    """The path for a market, resolved at CALL time.

    Module attributes (``MODEL_PATH``, ``GOAL_MODEL_PATH``) are the single source:
    reading ``os.environ`` here would make a test or operator override that sets the
    attribute silently ineffective, which is a worse failure than the import-time
    capture this replaced.
    """
    if market in _artifact_paths:
        return _artifact_paths[market]
    if market == "__goal__":
        return Path(GOAL_MODEL_PATH)
    if market == MARKET_1X2:
        return Path(MODEL_PATH)
    # Per-market default path, but honouring a test override of the artifacts
    # directory would need a second knob; ``set_artifact_path`` is that knob, so the
    # default is the documented on-disk location.
    return Path(_default_market_path(market))


def _get_artifact_path_for(market: str) -> Path:
    return _artifact_path(market)


def _get_artifact_path(market: str) -> Path:
    return _get_artifact_path_for(_artifact_market(market))


def set_artifact_path(market: str, path: str | Path) -> None:
    """Override the artifact path for a market (used by tests)."""
    _artifact_paths[market] = Path(path)


_model_caches: dict[str, Any] = {}

MARKET_1X2_CLASSES = frozenset({"H", "D", "A"})


def _legacy_mislabelled(market: str, declared: str, classes) -> bool:
    """True when a `1x2` label is provably a default rather than a claim."""
    return (
        declared == MARKET_1X2
        and market in TRAINED_MARKETS
        and market != MARKET_1X2
        and len(list(classes)) == 2
        and not set(classes).intersection(MARKET_1X2_CLASSES)
    )


def _load_artifact(path: Path, market_label: str, requested_market: str | None = None) -> Any:
    """Load an artifact (bundle or raw object) with a market-labelled error.

    ``requested_market`` is the market the CALLER asked for, when it differs from the
    artifact being loaded (correct score is served from the goal distribution). The
    error names the caller's market first, because that is what they can act on.
    """
    if not path.is_file():
        requested = requested_market or market_label
        raise HTTPException(
            status_code=503,
            detail=(
                f"no model is available for market '{requested}'"
                + (f" (served by the '{market_label}' artifact)" if requested != market_label else "")
                + f": artifact not found at {path}. The prediction was NOT generated; train "
                "and publish an artifact for this market before requesting it."
            ),
        )
    try:
        return load_bundle(path)
    except ModelError as exc:
        raise HTTPException(
            status_code=503,
            detail=f"the model for market '{market_label}' could not be loaded: {exc}",
        ) from exc


def _load_model(market: str) -> ModelBundle:
    check_market(market)
    if market in PROJECTED_MARKETS:
        raise HTTPException(
            status_code=400,
            detail=(
                f"market '{market}' is derived from another distribution and has no fitted "
                "artifact of its own. Double chance follows the 1X2 distribution; correct "
                "score follows the goal distribution (see GET /markets)."
            ),
        )
    global _model_caches
    if market not in _model_caches:
        _model_caches[market] = None
    if _model_caches[market] is None:
        artifact_path = _get_artifact_path(market)
        bundle = _load_artifact(artifact_path, market)
        declared = getattr(bundle, "market", UNKNOWN_MARKET)
        if declared not in (UNKNOWN_MARKET, market) and not _legacy_mislabelled(
            market, declared, bundle.classes
        ):
            raise HTTPException(
                status_code=503,
                detail=(
                    f"no model is available for market '{market}': the artifact at "
                    f"{artifact_path} declares market '{declared}'. Serving it under another "
                    "market's name would be misleading, so the request is refused."
                ),
            )
        if declared != market:
            logger.warning(
                "serving %s from an artifact labelled %r (classes=%s); retrain to stamp "
                "the correct market",
                market,
                declared,
                list(bundle.classes),
            )
        _model_caches[market] = bundle
    return _model_caches[market]


CLASSIFIER_MARKETS = {
    MARKET_1X2: (MARKET_1X2, list(CLASSES_1X2)),
    MARKET_OVER_UNDER: (MARKET_OVER_UNDER, ["Over", "Under"]),
    MARKET_BTTS: (MARKET_BTTS, ["Yes", "No"]),
}


def _load_goal_model() -> GoalDistributionPredictor:
    """The scoreline model, loaded once. 503 when it was never trained."""
    return _load_fixture_predictor().grid


def _load_fixture_predictor():
    """The goal distribution plus whichever per-market classifiers are published.

    Missing classifiers are NOT an error: the grid answers those markets. What is
    an error is having neither, which is when a 503 is the honest answer.
    """
    global _model_caches
    if _model_caches.get("__fixture__") is None:
        bundle = _load_artifact(_artifact_path("__goal__"), "goal_distribution")
        classifiers: dict[str, Any] = {}
        classes: dict[str, list[str]] = {}
        for market, (source, expected_classes) in CLASSIFIER_MARKETS.items():
            path = _get_artifact_path_for(market)
            if not path.is_file():
                continue
            try:
                classifier_bundle = load_bundle(path)
            except ModelError as exc:  # pragma: no cover - corrupt file on disk
                logger.warning("ignoring unreadable %s artifact: %s", market, exc)
                continue
            if list(classifier_bundle.classes) != expected_classes:
                # A model whose label set does not match the market is not a model
                # for that market, however it was named on disk.
                logger.warning(
                    "ignoring %s artifact with classes %s (expected %s)",
                    market,
                    classifier_bundle.classes,
                    expected_classes,
                )
                continue
            classifiers[market] = classifier_bundle.classifier
            classes[market] = expected_classes
        _model_caches["__fixture__"] = _FixturePredictor(
            bundle.classifier, classifiers, classes, list(FEATURE_NAMES_V2)
        )
    return _model_caches["__fixture__"]


def load_model(market: str = MARKET_1X2) -> None:
    """Public hook so tests can reset a cached artifact after swapping a path."""
    _model_caches[market] = None


# ---------------------------------------------------------------------------
# Liveness / readiness
# ---------------------------------------------------------------------------


@app.get("/health", response_model=Health, tags=["health"])
def health() -> Health:
    return Health(status="ok")


@app.get("/ready", tags=["readiness"])
def ready() -> JSONResponse:
    """Ready only when the markets that must exist are loadable.

    Correct score and the grid-derived binary markets may legitimately be served
    by the goal model, so readiness requires 1X2 plus at least one grid source.
    Reporting "ready" while a required market cannot be served is how a client
    ends up with a 503 in production after a green health check.
    """
    checks: dict[str, str] = {}
    try:
        _load_model(MARKET_1X2)
        checks["1x2"] = "ok"
    except HTTPException:
        checks["1x2"] = "missing"
    try:
        _load_goal_model()
        checks["goal_distribution"] = "ok"
    except HTTPException:
        checks["goal_distribution"] = "missing"
    healthy = all(value == "ok" for value in checks.values())
    return JSONResponse(
        content={"status": "ready" if healthy else "not_ready", "checks": checks},
        status_code=200 if healthy else 503,
    )


# ---------------------------------------------------------------------------
# Model status
# ---------------------------------------------------------------------------


@app.get("/model/status", response_model=ModelStatus, tags=["model"])
def model_status(market: str = MARKET_1X2) -> ModelStatus:
    check_market(market)
    # Every derived market is refused here, correct score included. Status reports a
    # FITTED artifact; a projection has none, and reporting the 1X2 model under a
    # derived market's name is how a client ends up believing a fitted model exists.
    bundle = _load_model(market)
    return ModelStatus(
        market=market,
        model_version=bundle.model_version,
        trained_at=bundle.trained_at.isoformat()
        if hasattr(bundle.trained_at, "isoformat")
        else str(bundle.trained_at),
        classes=list(bundle.classes),
        feature_names=list(bundle.feature_names),
    )


@app.get("/markets", tags=["model"])
def markets() -> dict[str, Any]:
    """Which markets are actually serviceable right now, and from what.

    A client-facing inventory: an operator can see at a glance whether a missing
    market is a deployment problem or an expected absence.
    """
    inventory: dict[str, Any] = {}
    for market in SUPPORTED_MARKETS:
        if market == MARKET_DOUBLE_CHANCE:
            inventory[market] = {"source": "derived from 1x2", "available": MARKET_1X2 in inventory and inventory[MARKET_1X2]["available"]}
            continue
        if market == MARKET_CORRECT_SCORE:
            inventory[market] = {
                "source": "goal distribution",
                "available": _artifact_path("__goal__").is_file(),
            }
            continue
        if market in (MARKET_OVER_UNDER, MARKET_BTTS):
            own = _get_artifact_path_for(market).is_file()
            inventory[market] = {
                "source": "own artifact" if own else "missing",
                "available": own,
            }
            continue
        inventory[market] = {
            "source": "own artifact",
            "available": _get_artifact_path_for(market).is_file(),
        }
    return {"markets": inventory}


# ---------------------------------------------------------------------------
# Prediction
# ---------------------------------------------------------------------------


def _flat_features_predict(market: str, features: dict[str, float]) -> PredictResponse:
    if market == MARKET_DOUBLE_CHANCE:
        bundle = _load_model(MARKET_1X2)
        probabilities = double_chance_probabilities(
            _classifier_probabilities(bundle, features)
        )
        return PredictResponse(
            market=market,
            probabilities=probabilities,
            model_version=bundle.model_version,
            predicted_at=datetime.now(timezone.utc).isoformat(),
            feature_version="v1",
            **_provenance_for(market, "classifier"),
        )

    if market in (MARKET_CORRECT_SCORE,):
        raise HTTPException(
            status_code=400,
            detail="correct_score needs a match history; use POST /predict/from-history/correct_score",
        )

    bundle = _load_model(market)
    probabilities = _classifier_probabilities(bundle, features)
    return PredictResponse(
        market=market,
        probabilities=probabilities,
        model_version=bundle.model_version,
        predicted_at=datetime.now(timezone.utc).isoformat(),
        feature_version="v1",
        **_provenance_for(market, "classifier"),
    )


def _classifier_probabilities(bundle: ModelBundle, features: dict[str, float]) -> dict[str, float]:
    try:
        return predict_proba(bundle.classifier, features, bundle)
    except ModelError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/predict", response_model=PredictResponse, tags=["prediction"])
def predict(req: PredictRequest, market: str = MARKET_1X2) -> PredictResponse:
    """Flat-feature prediction. ``market`` is a query parameter, never a body key."""
    check_market(market)
    return _flat_features_predict(market, req.model_dump())


@app.post("/predict/{market}", response_model=PredictResponse, tags=["prediction"])
def predict_market(market: str, req: PredictRequest) -> PredictResponse:
    """Market-specific flat-feature prediction.

    The body must contain exactly the 17 feature names; the market travels in the
    path only. The previous signature accepted a body with an optional ``market``
    key, which silently allowed the PATH and the BODY to disagree.
    """
    check_market(market)
    return _flat_features_predict(market, req.model_dump())


@app.post("/predict/from-history/{market}", response_model=PredictResponse, tags=["prediction"])
def predict_from_history(
    market: str,
    req: HistoryPredictRequest,
    source: Literal["goal_model", "classifier"] = "goal_model",
) -> PredictResponse:
    """Predict from a match plus its history, computing features here.

    This is the endpoint Rails should prefer: it is the only place that knows how
    to turn history into a feature vector, so Rails cannot drift from training.

    ``source`` chooses which published model answers:

    * ``goal_model`` (DEFAULT) — the joint scoreline distribution. Every market is
      a view of one grid, so 1X2, Over/Under, BTTS and Double Chance cannot
      contradict each other, and a prediction is a real distribution rather than a
      confident label.
    * ``classifier`` — the per-market model with the better held-out log loss
      (0.999 vs 1.011 on the untouched test window). It is OPT-IN, not the default,
      because on this dataset it is badly overconfident: it assigns 1.0/0.0/0.0 to
      ordinary fixtures (mean max probability 0.977, P(draw) ≈ 0). Log loss scores
      that better than the grid, so the metric alone would promote it; the
      predictions themselves are not usable as prices. The comparison is one query
      parameter away, and docs/model-training.md records both numbers.

    This default was switched after measuring both on the same fixture; it is a
    documented, reversible choice rather than a silent preference.

    Double chance is ALWAYS the 1X2 projection, whichever source is selected: a
    double chance that disagrees with the 1X2 beside it is a contradiction, not a
    modelling choice.
    """
    check_market(market)
    match = req.match.model_dump()
    history = [entry.model_dump() for entry in req.history]

    try:
        predictor = _load_fixture_predictor()
    except HTTPException as exc:
        if exc.status_code == 503:
            raise HTTPException(
                status_code=503,
                detail=(
                    f"no model is available for market '{market}': the goal-distribution "
                    "artifact is not published, so no scoreline distribution can be built. "
                    "Nothing was predicted."
                ),
            ) from exc
        raise

    if market == MARKET_DOUBLE_CHANCE:
        probabilities = predictor.grid.market(match, history, MARKET_DOUBLE_CHANCE)
        if source == "goal_model":
            probabilities = predictor.grid.market(match, history, MARKET_DOUBLE_CHANCE)
        else:
            one_x_two = predictor.classifier_probabilities_for(
                match, feature_vector_for(match, history)[0], MARKET_1X2
            )
            if one_x_two is not None:
                probabilities = double_chance_probabilities(one_x_two)
        version = _version_for(MARKET_1X2, source)
    elif source == "goal_model" or market == MARKET_CORRECT_SCORE:
        probabilities = predictor.grid.market(match, history, market)
        version = _version_for(market, "goal_model")
    else:
        probabilities = predictor.market(match, history, market)
        version = _version_for(market, source)

    return PredictResponse(
        market=market,
        probabilities=probabilities,
        model_version=version,
        predicted_at=datetime.now(timezone.utc).isoformat(),
        feature_version="v2",
        # The SAME source that produced `version`, so provenance and model_version
        # can never describe different artifacts.
        **_provenance_for(
            MARKET_1X2 if market == MARKET_DOUBLE_CHANCE else market,
            "goal_model" if (source == "goal_model" or market == MARKET_CORRECT_SCORE) else source,
        ),
    )


def _artifacts_dir() -> str:
    """Resolved at call time, not import time.

    Reading the environment per call lets a test point inference at a synthetic
    directory without reloading this module (which would leave other tests sharing a
    stale module object).
    """
    return os.environ.get("MODEL_ARTIFACTS_DIR", ARTIFACTS_DIR)


def _freeze_path() -> str:
    return os.environ.get("MODEL_FREEZE_PATH", FREEZE_PATH)


def _provenance_for(market: str, source: str) -> dict:
    """Provenance of the artifact that actually answered this request.

    The digest is recomputed from the file on disk for the market/source that
    produced the probabilities, then checked against the freeze record. It is never
    read from a constant: a constant would claim the frozen generation even if the
    artifact had been replaced.

    Any failure to verify yields `model_freeze_digest=None` plus a status, so Rails
    stores NULL and its eligibility check treats the prediction as unattributable.
    """
    try:
        artifact = _artifact_path_for(market, source)
        freeze = load_freeze(_freeze_path())
        return ArtifactProvenance.for_artifact(artifact, freeze=freeze).to_response_fields()
    except Exception as exc:  # pragma: no cover - defensive
        # Provenance must never break inference; it degrades to "unavailable".
        logger.warning("provenance unavailable for %s/%s: %s", market, source, exc)
        return {
            "model_freeze_digest": None,
            "artifact_sha256": None,
            "provenance_status": PROVENANCE_UNAVAILABLE,
            "feature_version": None,
        }


def _artifact_path_for(market: str, source: str) -> Path:
    """The artifact file behind a market/source pair.

    Mirrors the registry's own resolution: ONE goal-distribution artifact answers
    correct score and every derived market (1X2, O/U, BTTS, double chance), and one
    classifier answers the rest. Verified against the files present in
    `ml/artifacts/` — the goal model is `model_goal_distribution.joblib`, NOT a
    per-market `poisson_*.joblib`, which does not exist.
    """
    # One goal-distribution artifact answers every market derived from the score
    # grid; the classifier answers 1X2 when source selection says so. Simplifying the
    # condition matters: the previous version mixed `or` with a trailing `and` and
    # relied on operator precedence.
    if source == "goal_model":
        return Path(f"{_artifacts_dir()}/model_goal_distribution.joblib")
    if market == MARKET_CORRECT_SCORE:
        # Correct score is ALWAYS the grid, whatever the source parameter says.
        return Path(f"{_artifacts_dir()}/model_goal_distribution.joblib")
    return Path(f"{_artifacts_dir()}/model_{market}.joblib")


def _version_for(market: str, source: str) -> str:
    if source == "goal_model" or market == MARKET_CORRECT_SCORE:
        goal_bundle = _load_artifact(_artifact_path("__goal__"), "goal_distribution")
        return f"{getattr(goal_bundle, 'model_version', 'goal-distribution')}:goal_model"
    predictor = _load_fixture_predictor()
    if market in predictor.classifiers:
        bundle = load_bundle(_get_artifact_path_for(market))
        return f"{bundle.model_version}:classifier"
    # No per-market classifier published: the grid answered.
    return _version_for(market, "goal_model")


def _predictor_for(market: str) -> GoalDistributionPredictor:
    """The predictor that serves a history-based request for ``market``.

    Grid-derived markets (1X2, over/under, BTTS, correct score) always use the goal
    distribution so they stay mutually consistent. A trained per-market classifier
    is used by the flat-feature endpoint, where the caller already fixed the number
    of inputs; mixing the two inside one response would break consistency, which is
    the whole reason for serving a single grid.
    """
    try:
        return _load_goal_model()
    except HTTPException:
        # No grid model published. The grid-derived markets cannot be answered, and
        # saying so is better than substituting a different distribution.
        raise HTTPException(
            status_code=503,
            detail=(
                f"no model is available for market '{market}' from a match history: the "
                "goal-distribution artifact is not published. Nothing was predicted."
            ),
        )


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------


@app.get("/metrics", tags=["metrics"])
def metrics_endpoint(market: str = MARKET_1X2) -> dict[str, float]:
    check_market(market)
    metrics_path = Path(METRICS_PATH)
    if not metrics_path.is_file():
        raise HTTPException(
            status_code=404,
            detail="model metrics not available — no held-out evaluation data present",
        )
    try:
        raw = json.loads(metrics_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise HTTPException(status_code=500, detail="model metrics file is corrupt") from exc

    entry = raw
    if isinstance(raw, dict) and "markets" in raw:
        for item in raw["markets"]:
            if item.get("market") == market:
                entry = item.get("test", {}).get("metrics", {})
                break
        else:
            raise HTTPException(
                status_code=404, detail=f"metrics for market '{market}' are not available"
            )
    if "market" in entry and entry["market"] != market:
        raise HTTPException(
            status_code=404, detail=f"metrics for market '{market}' are not available"
        )
    try:
        return {
            "accuracy": float(entry["accuracy"]),
            "log_loss": float(entry["log_loss"]),
            "brier_score": float(entry["brier_score"]),
        }
    except (KeyError, TypeError, ValueError) as exc:
        raise HTTPException(status_code=404, detail="held-out metrics are not available for this market") from exc


# ---------------------------------------------------------------------------
# Error handling: always JSON, never a stack trace
# ---------------------------------------------------------------------------


@app.exception_handler(Exception)
def unexpected_error_handler(request: Request, exc: Exception) -> JSONResponse:
    """Never leak a stack trace, and never fail while rendering an error.

    A rejected non-finite float is not JSON-serialisable, and some client versions
    refuse to encode one in a request body at all. Either way the client gets a
    clean JSON body instead of an HTML traceback.
    """
    logger.exception("unhandled error on %s %s", request.method, request.url.path)
    return JSONResponse(status_code=500, content={"detail": "internal error"})


@app.exception_handler(HistoryError)
def history_error_handler(request: Request, exc: HistoryError) -> JSONResponse:
    return JSONResponse(status_code=400, content={"detail": str(exc)})


@app.exception_handler(RequestValidationError)
def validation_error_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
    """Report a schema violation as a clean 422, never a 500.

    The default handler re-serialises the rejected VALUE into the error body. A
    rejected NaN or Infinity is not representable in JSON, so the default handler
    raises while rendering — turning "you sent a bad number" into an unrelated
    server error. Only the field and the message are returned here.
    """
    errors = [
        {
            "loc": [str(part) for part in error.get("loc", ())],
            "msg": str(error.get("msg", "")),
            "type": str(error.get("type", "")),
        }
        for error in exc.errors()
    ]
    return JSONResponse(status_code=422, content={"detail": errors})
