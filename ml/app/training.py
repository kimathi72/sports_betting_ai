"""Historical data client + training pipeline for the 1X2 baseline.

The training data comes from the existing Rails API endpoint
``GET /api/v1/matches?status=completed`` via HTTP (never synthetic data).
Matches are sorted chronologically and features are computed with a strict
``compute_match_features`` call that only consumes matches completed strictly
before the target kickoff — preventing target leakage.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any

import numpy as np

from ml.app.features import FEATURE_NAMES, compute_match_features, target_label, over_under_target, btts_target
from ml.app.metrics import evaluate_predictions, _reorder_proba_to_canonical, _reorder_proba, binary_evaluate_predictions, binary_uniform_baseline, binary_frequency_baseline
from ml.app.model import train_baseline, train_binary_classifier
from ml.app.model_store import ModelBundle, save_bundle, MARKET_1X2, MARKET_OVER_UNDER, MARKET_BTTS


class TrainingDataError(RuntimeError):
    """Raised when historical training data cannot be fetched or prepared."""


def discover_season_ids(base_url: str) -> list[int]:
    """Return the ids of seasons that have at least one completed match.

    Seasons are DISCOVERED, never hardcoded. A hardcoded list silently produced an
    empty or wrong dataset after any re-import, because PostgreSQL ids are not
    stable: inserting one match can renumber every season.

    Seasons with no completed matches are skipped — they cannot contribute a
    training row, and including them would make every fetch return nothing while
    looking successful.

    Raises TrainingDataError when the endpoint is unreachable, malformed, empty,
    or reports no completed matches at all: silently training on nothing is worse
    than failing.
    """
    import httpx

    url = f"{base_url.rstrip('/')}/api/v1/seasons"
    try:
        response = httpx.get(url, timeout=30.0, headers={"Accept": "application/json"})
        response.raise_for_status()
    except Exception as exc:  # noqa: BLE001 - any transport error is a data failure
        raise TrainingDataError(f"could not fetch seasons from {url}: {exc}") from exc

    try:
        payload = response.json()
    except ValueError as exc:
        raise TrainingDataError("seasons response is not JSON") from exc

    if not isinstance(payload, list):
        raise TrainingDataError("seasons response is not a JSON array")

    season_ids = sorted(
        int(season["id"])
        for season in payload
        if isinstance(season, dict) and int(season.get("completed_match_count", 0) or 0) > 0
    )

    if not season_ids:
        raise TrainingDataError(
            "no seasons with completed matches were returned; import historical data first"
        )

    return season_ids


def fetch_all_completed_matches(base_url: str) -> list[dict]:
    """Fetch completed matches from all known seasons, deduplicating by match ID.

    The Rails API caps results at 2000 per request, so we iterate over discovered
    seasons
    and keep only the first occurrence of each match ID to avoid duplicates.
    """
    import httpx

    seen_ids: set[int] = set()
    all_matches: list[dict] = []

    for season_id in discover_season_ids(base_url):
        url = f"{base_url.rstrip('/')}/api/v1/matches?status=completed&limit=2000&season_id={season_id}"
        try:
            response = httpx.get(url, timeout=30.0, headers={"Accept": "application/json"})
            response.raise_for_status()
            try:
                payload = response.json()
            except ValueError:
                raise TrainingDataError(
                    f"completed matches response was not a JSON array for season {season_id}"
                )
        except Exception as exc:  # noqa: BLE001
            raise TrainingDataError(
                f"failed to fetch completed matches from season {season_id}: {exc}"
            ) from exc

        if not isinstance(payload, list):
            raise TrainingDataError(
                f"completed matches response was not a JSON array for season {season_id}"
            )

        for m in payload:
            mid = m.get("id")
            if mid is not None and mid not in seen_ids:
                seen_ids.add(mid)
                all_matches.append(m)

    return all_matches


def fetch_completed_matches(base_url: str, season_id: int | None = None) -> list[dict]:
    """Fetch completed matches from the Rails API.

    Never silently substitutes synthetic data: HTTP or payload failures raise.
    """
    import httpx

    url = f"{base_url.rstrip('/')}/api/v1/matches?status=completed&limit=2000"
    if season_id is not None:
        url += f"&season_id={season_id}"

    try:
        response = httpx.get(url, timeout=30.0, headers={"Accept": "application/json"})
        response.raise_for_status()
        try:
            payload = response.json()
        except ValueError:
            raise TrainingDataError("completed matches response was not a JSON array")
    except Exception as exc:  # noqa: BLE001
        raise TrainingDataError(f"failed to fetch completed matches from {url}: {exc}") from exc

    if not isinstance(payload, list):
        raise TrainingDataError("completed matches response was not a JSON array")
    return payload


def build_training_dataset(matches: list[dict]) -> tuple[np.ndarray, np.ndarray]:
    """Build X (features) and y (H/D/A) from completed matches, chronological.

    Only completed matches with both scores are targets. Features for each
    match are computed from strictly-earlier completed matches only — the
    history passed to ``compute_match_features`` is the sorted list of all
    matches before the current index, and the feature function internally
    filters out anything at or after the target kickoff.
    """
    sorted_matches = sorted(
        matches,
        key=lambda m: (m.get("kickoff_at") or "", m.get("id") or 0),
    )

    X_rows: list[list[float]] = []
    y_labels: list[str] = []

    for i, m in enumerate(sorted_matches):
        if m.get("status") != "completed":
            continue
        if m.get("home_score") is None or m.get("away_score") is None:
            continue

        # History is every match strictly before index i; compute_match_features
        # further filters to completed matches with scores before kickoff.
        features = compute_match_features(m, history=sorted_matches[:i])
        X_rows.append([features[name] for name in FEATURE_NAMES])
        y_labels.append(target_label(m))

    X = np.array(X_rows, dtype=float)
    y = np.array(y_labels, dtype=object)
    return X, y


def train_from_matches(
    matches: list[dict],
    model_version: str = "0.1.0",
) -> tuple[Any, ModelBundle, dict[str, float]]:
    """Train baseline on chronological completed matches.

    Returns (classifier, bundle, metrics).
    """
    X, y = build_training_dataset(matches)
    if X.shape[0] < 30:
        raise TrainingDataError(f"insufficient training samples: {X.shape[0]} < 30")

    clf, bundle = train_baseline(X, y, model_version=model_version)

    # Held-out evaluation on the chronological 20% split
    split_idx = int(X.shape[0] * 0.8)
    X_val, y_val = X[split_idx:], y[split_idx:]
    y_val_proba_raw = clf.predict_proba(X_val)
    y_val_proba = _reorder_proba_to_canonical(y_val_proba_raw, list(clf.classes_))
    y_val_pred = clf.predict(X_val)

    try:
        metrics = evaluate_predictions(y_val, y_val_proba, y_val_pred)
    except Exception:
        metrics = {"accuracy": 0.0, "log_loss": 0.0, "brier_score": 0.0}

    return clf, bundle, metrics


def build_over_under_dataset(matches: list[dict]) -> tuple[np.ndarray, np.ndarray]:
    """Build X (features) and y (Over/Under) from completed matches, chronological."""
    sorted_matches = sorted(
        matches,
        key=lambda m: (m.get("kickoff_at") or "", m.get("id") or 0),
    )

    X_rows: list[list[float]] = []
    y_labels: list[str] = []

    for i, m in enumerate(sorted_matches):
        if m.get("status") != "completed":
            continue
        if m.get("home_score") is None or m.get("away_score") is None:
            continue

        features = compute_match_features(m, history=sorted_matches[:i])
        X_rows.append([features[name] for name in FEATURE_NAMES])
        y_labels.append(over_under_target(m))

    X = np.array(X_rows, dtype=float)
    y = np.array(y_labels, dtype=object)
    return X, y


def build_btts_dataset(matches: list[dict]) -> tuple[np.ndarray, np.ndarray]:
    """Build X (features) and y (BTTS Yes/No) from completed matches, chronological."""
    sorted_matches = sorted(
        matches,
        key=lambda m: (m.get("kickoff_at") or "", m.get("id") or 0),
    )

    X_rows: list[list[float]] = []
    y_labels: list[str] = []

    for i, m in enumerate(sorted_matches):
        if m.get("status") != "completed":
            continue
        if m.get("home_score") is None or m.get("away_score") is None:
            continue

        features = compute_match_features(m, history=sorted_matches[:i])
        X_rows.append([features[name] for name in FEATURE_NAMES])
        y_labels.append(btts_target(m))

    X = np.array(X_rows, dtype=float)
    y = np.array(y_labels, dtype=object)
    return X, y


def train_over_under(
    matches: list[dict],
    model_version: str = "0.1.0",
) -> tuple[Any, ModelBundle, dict[str, float]]:
    """Train Over/Under 2.5 binary classifier on chronological completed matches."""
    X, y = build_over_under_dataset(matches)
    if X.shape[0] < 30:
        raise TrainingDataError(f"insufficient training samples: {X.shape[0]} < 30")

    clf, bundle = train_binary_classifier(
        X, y, model_version=model_version, market=MARKET_OVER_UNDER
    )

    # Held-out evaluation on the chronological 20% split
    split_idx = int(X.shape[0] * 0.8)
    X_val, y_val = X[split_idx:], y[split_idx:]
    y_val_proba_raw = clf.predict_proba(X_val)
# Reorder to match bundle.classes order (binary: alphabetically sorted from sklearn)
    y_val_proba = _reorder_proba(y_val_proba_raw, list(clf.classes_), list(bundle.classes))
    y_val_pred = clf.predict(X_val)

    try:
        metrics = binary_evaluate_predictions(y_val, y_val_proba, y_val_pred, list(bundle.classes))
    except Exception:
        metrics = {"accuracy": 0.0, "log_loss": 0.0, "brier_score": 0.0}

    # Compare against baselines
    try:
        uniform_baseline = binary_uniform_baseline(y_val, list(bundle.classes))
        freq_baseline = binary_frequency_baseline(y_val, list(bundle.classes))
        metrics["uniform_baseline_log_loss"] = uniform_baseline["log_loss"]
        metrics["frequency_baseline_log_loss"] = freq_baseline["log_loss"]
    except Exception:
        pass

    return clf, bundle, metrics


def train_btts(
    matches: list[dict],
    model_version: str = "0.1.0",
) -> tuple[Any, ModelBundle, dict[str, float]]:
    """Train Both Teams to Score binary classifier on chronological completed matches."""
    X, y = build_btts_dataset(matches)
    if X.shape[0] < 30:
        raise TrainingDataError(f"insufficient training samples: {X.shape[0]} < 30")

    clf, bundle = train_binary_classifier(
        X, y, model_version=model_version, market=MARKET_BTTS
    )

    # Held-out evaluation on the chronological 20% split
    split_idx = int(X.shape[0] * 0.8)
    X_val, y_val = X[split_idx:], y[split_idx:]
    y_val_proba_raw = clf.predict_proba(X_val)
    y_val_proba = _reorder_proba(y_val_proba_raw, list(clf.classes_), list(bundle.classes))
    y_val_pred = clf.predict(X_val)

    try:
        metrics = binary_evaluate_predictions(y_val, y_val_proba, y_val_pred, list(bundle.classes))
    except Exception:
        metrics = {"accuracy": 0.0, "log_loss": 0.0, "brier_score": 0.0}

    # Compare against baselines
    try:
        uniform_baseline = binary_uniform_baseline(y_val, list(bundle.classes))
        freq_baseline = binary_frequency_baseline(y_val, list(bundle.classes))
        metrics["uniform_baseline_log_loss"] = uniform_baseline["log_loss"]
        metrics["frequency_baseline_log_loss"] = freq_baseline["log_loss"]
    except Exception:
        pass

    return clf, bundle, metrics


def train_double_chance(
    matches: list[dict],
    model_version: str = "0.1.0",
) -> tuple[Any, ModelBundle, dict[str, float]]:
    """Train 1X2 baseline (reusing existing) and report Double Chance derived metrics.

    Double Chance probabilities are derived from 1X2 probabilities:
    - 1X = P(H) + P(D)
    - X2 = P(D) + P(A)
    - 12 = P(H) + P(A)

    This function trains the 1X2 model and returns it along with Double Chance
    evaluation metrics on the holdout set.
    """
    # Train 1X2 model
    clf, bundle, _ = train_from_matches(matches, model_version)

    # Evaluate Double Chance on holdout
    X, y = build_training_dataset(matches)
    split_idx = int(X.shape[0] * 0.8)
    X_val, y_val = X[split_idx:], y[split_idx:]

    # Get 1X2 probabilities
    y_val_proba_raw = clf.predict_proba(X_val)
    y_val_proba_1x2 = _reorder_proba_to_canonical(y_val_proba_raw, list(clf.classes_))

    # Derive Double Chance probabilities for each sample
    # 1X = H + D, X2 = D + A, 12 = H + A
    dc_proba = np.column_stack([
        y_val_proba_1x2[:, 0] + y_val_proba_1x2[:, 1],  # 1X
        y_val_proba_1x2[:, 1] + y_val_proba_1x2[:, 2],  # X2
        y_val_proba_1x2[:, 0] + y_val_proba_1x2[:, 2],  # 12
    ])

    # Double Chance "target" - we derive it from 1X2 true labels
    # For each sample, the true Double Chance outcomes are:
    # If H: 1X=True, X2=False, 12=True
    # If D: 1X=True, X2=True, 12=False
    # If A: 1X=False, X2=True, 12=True
    dc_labels = {
        "1X": np.array([1 if c in ("H", "D") else 0 for c in y_val]),
        "X2": np.array([1 if c in ("D", "A") else 0 for c in y_val]),
        "12": np.array([1 if c in ("H", "A") else 0 for c in y_val]),
    }

    dc_metrics = {}
    for market_name in ["1X", "X2", "12"]:
        y_true = dc_labels[market_name]
        y_proba = dc_proba[:, ["1X", "X2", "12"].index(market_name)]
        y_pred = (y_proba >= 0.5).astype(int)
        try:
            # Binary evaluation
            m = binary_evaluate_predictions(
                y_true.astype(str),
                np.column_stack([1 - y_proba, y_proba]),
                y_pred.astype(str),
                ["0", "1"],
            )
            dc_metrics[f"{market_name}_accuracy"] = m["accuracy"]
            dc_metrics[f"{market_name}_log_loss"] = m["log_loss"]
            dc_metrics[f"{market_name}_brier_score"] = m["brier_score"]
        except Exception:
            dc_metrics[f"{market_name}_accuracy"] = 0.0
            dc_metrics[f"{market_name}_log_loss"] = 0.0
            dc_metrics[f"{market_name}_brier_score"] = 0.0

    # Return the 1X2 bundle with Double Chance metrics added
    # Note: Double Chance uses the same 1X2 model, so bundle is the 1X2 bundle
    combined_metrics = {}
    combined_metrics.update(dc_metrics)
    return clf, bundle, combined_metrics


def save_artifacts(
    bundle: ModelBundle,
    metrics: dict[str, float],
    model_path: Path,
) -> None:
    """Persist model bundle and metrics JSON to the artifacts directory."""
    model_path.parent.mkdir(parents=True, exist_ok=True)
    save_bundle(bundle, model_path)
    metrics_path = model_path.parent / "metrics.json"
    metrics_output = {
        "model_version": bundle.model_version,
        "feature_names": list(bundle.feature_names),
        "classes": list(bundle.classes),
        **metrics,
    }
    metrics_path.write_text(json.dumps(metrics_output, indent=2, default=str))


def main() -> None:
    # Configuration via environment variables
    rails_base_url = os.getenv("RAILS_BASE_URL", "http://web:3000")
    season_id_env = os.getenv("SEASON_ID")
    season_id = int(season_id_env) if season_id_env else None
    model_version = os.getenv("MODEL_VERSION", "0.1.0")
    model_path = Path(os.getenv("ML_MODEL_PATH", "/app/artifacts/model.joblib"))

    print(f"Fetching completed matches from {rails_base_url}...")
    if season_id is not None:
        matches = fetch_completed_matches(rails_base_url, season_id)
        print(f"Retrieved {len(matches)} matches for season {season_id}")
    else:
        matches = fetch_all_completed_matches(rails_base_url)
        print(f"Retrieved {len(matches)} matches across all seasons")

    print("Training baseline...")
    clf, bundle, metrics = train_from_matches(matches, model_version)
    print(f"Training complete: {metrics}")

    print(f"Saving model to {model_path}...")
    save_artifacts(bundle, metrics, model_path)
    print("Done.")


if __name__ == "__main__":
    main()
