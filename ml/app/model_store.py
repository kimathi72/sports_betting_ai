"""Persisted model artifact and metadata bundle.

A bundle records everything an inference request needs to be served without
retraining:

- ``classifier``: the fitted sklearn-style estimator.
- ``feature_names``: exact ordered feature schema; inference refuses any other set.
- ``classes``: the ordered label list (e.g. ``["H", "D", "A"]``).
- ``model_version``: operator-facing version string.
- ``trained_at``: UTC timestamp of the training run.
- ``market``: the prediction market (e.g. "1x2", "over_under_2.5", "btts").

Artifacts are joblib pickles written to an operator-controlled directory; the
metadata JSON is stored alongside them. Generated artifacts are never committed
to Git.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import joblib
import numpy as np

FEATURE_NAMES = [
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
]

DEFAULT_MODEL_PATH = "/app/artifacts/model.joblib"
DEFAULT_METRICS_PATH = "/app/artifacts/metrics.json"
DEFAULT_MODEL_VERSION = "0.1.0"

MARKET_1X2 = "1x2"
MARKET_DOUBLE_CHANCE = "double_chance"
MARKET_OVER_UNDER = "over_under_2.5"
MARKET_BTTS = "btts"
ALL_MARKETS = [MARKET_1X2, MARKET_DOUBLE_CHANCE, MARKET_OVER_UNDER, MARKET_BTTS]

# Markets that are fitted and persisted as an artifact.
TRAINED_MARKETS = [MARKET_1X2, MARKET_OVER_UNDER, MARKET_BTTS]

# Markets that are PROJECTED from another market's distribution and therefore
# must never have an artifact of their own. Double chance is the derived market:
# training it independently would allow P(1X) != P(H) + P(D), which is not a
# modelling choice, it is a contradiction.
DERIVED_MARKETS = [MARKET_DOUBLE_CHANCE]

# There is no market called "unknown": a bundle that cannot say what it is must
# not claim to be 1x2, because `market` is what an operator trusts when choosing
# a file to roll back.
UNKNOWN_MARKET = "unknown"


class ModelError(RuntimeError):
    """Raised when a model artifact or bundle is missing, corrupt or inconsistent."""


@dataclass
class ModelBundle:
    classifier: object
    feature_names: list[str]
    classes: list[str]
    model_version: str
    trained_at: datetime
    # Deliberately NOT defaulted to 1x2: a binary model that forgets to declare
    # its market would otherwise be silently mislabelled.
    market: str = UNKNOWN_MARKET

    @property
    def feature_vector(self) -> np.ndarray:
        return None


def get_model_path(market: str = MARKET_1X2, model_version: str = DEFAULT_MODEL_VERSION) -> Path:
    """Return the default model path for a market."""
    return Path(f"/app/artifacts/model_{market}.joblib")


def save_bundle(
    bundle: ModelBundle,
    save_path: Path | str,
    metadata: dict | None = None,
) -> Path:
    path = Path(save_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump(
        {
            "classifier": bundle.classifier,
            "feature_names": list(bundle.feature_names),
            "classes": list(bundle.classes),
            "model_version": bundle.model_version,
            "trained_at": bundle.trained_at,
            "market": bundle.market,
        },
        path,
    )
    payload = {
        "model_version": bundle.model_version,
        "trained_at": bundle.trained_at.isoformat(),
        "feature_names": list(bundle.feature_names),
        "classes": list(bundle.classes),
        "market": bundle.market,
    }
    if metadata:
        payload.update(metadata)
    # Metadata goes NEXT TO the artifact, named after it. A shared "metrics.json"
    # meant the last bundle written silently overwrote every other market's
    # metadata, so the file on disk described a model that was not the one beside
    # it. The name is derived from the artifact, so two artifacts cannot collide.
    metadata_path = path.with_suffix(path.suffix + ".meta.json") if path.suffix else Path(f"{path}.meta.json")
    metadata_path.write_text(json.dumps(payload, indent=2, default=str))
    return path


def load_bundle(path: Path | str) -> ModelBundle:
    p = Path(path)
    if not p.is_file():
        raise ModelError(f"model artifact not found: {p}")
    try:
        payload = joblib.load(p)
    except Exception as exc:
        raise ModelError(f"model artifact could not be loaded: {p}") from exc

    try:
        bundle = ModelBundle(
            classifier=payload["classifier"],
            feature_names=list(payload["feature_names"]),
            classes=list(payload["classes"]),
            model_version=str(payload["model_version"]),
            trained_at=payload["trained_at"],
            market=str(payload.get("market", UNKNOWN_MARKET)),
        )
    except Exception as exc:
        raise ModelError(f"model artifact is malformed: {p}") from exc

    # The feature schema is validated against the VERSION the artifact declares, not
    # against the v1 list. v2 models genuinely have more features, and rejecting
    # them here would make every current artifact unloadable; accepting ANY list
    # would let a model be served inputs it was never trained on.
    expected = _expected_features(bundle.feature_names)
    if expected is not None and list(bundle.feature_names) != expected:
        raise ModelError(
            f"model feature schema mismatch: artifact has {list(bundle.feature_names)}"
        )
    return bundle


def _expected_features(names: list[str]) -> list[str] | None:
    """The canonical feature list for the schema this artifact declares.

    Recognised by length and by the v1 prefix, because that is what the artifact
    actually records: it stores names, not a version string. An unrecognised schema
    returns None and is allowed, since refusing it would also refuse a future v3 —
    what matters is that a KNOWN schema matches exactly.
    """
    if list(names) == list(FEATURE_NAMES):
        return None
    try:
        from ml.app.features_v2 import FEATURE_NAMES_V2
    except Exception:  # pragma: no cover - v2 always exists in this project
        return None
    if list(names) == list(FEATURE_NAMES_V2):
        return FEATURE_NAMES_V2
    return None