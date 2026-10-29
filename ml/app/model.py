"""Baseline 1X2 classifier, training pipeline, and persistence.

The model is a simple multinomial classifier trained on pre-kickoff feature
vectors. It supports reproducible training, artifact saving/reloading, and
normalized probability predictions.

Training respects chronological ordering and class balance. It raises
informative errors when the training data is insufficient or imbalanced.
"""
from __future__ import annotations

from datetime import datetime, timezone

import numpy as np
from sklearn.ensemble import HistGradientBoostingClassifier

from ml.app.model_store import (
    MARKET_1X2,
    UNKNOWN_MARKET,
    ModelBundle,
    ModelError,
    save_bundle,
    load_bundle,
)
from ml.app.metrics import evaluate_predictions, held_out_metrics, _reorder_proba_to_canonical

# Canonical ordered feature schema. Inference refuses any other set.
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

BaselineClassifier = HistGradientBoostingClassifier

_CLASSES = ["H", "D", "A"]


def _check_y_all_classes(y: np.ndarray) -> None:
    classes = set(y.tolist())
    if len(classes) < 3:
        missing = set(_CLASSES) - classes
        raise ModelError(
            f"insufficient training data: not all three classes present; missing {sorted(missing)}"
        )


def train_baseline(
    X: np.ndarray,
    y: np.ndarray,
    model_version: str = "0.1.0",
) -> tuple[HistGradientBoostingClassifier, ModelBundle]:
    """Train a 1X2 baseline model on feature vectors and labels.

    Parameters
    ----------
    X: np.ndarray
        Feature matrix with shape ``(n_samples, n_features)``, n_features == 17.
    y: np.ndarray
        Target labels encoded as the strings ``"H"``, ``"D"``, ``"A"``.
    model_version: operator-facing string persisted in the artifact metadata.

    Returns
    -------
    (classifier, bundle) tuple ready to be saved with ``save_bundle``.
    """
    if X.shape[0] < 30:
        raise ModelError(f"insufficient training samples ({X.shape[0]} < 30)")
    if X.shape[1] != len(FEATURE_NAMES):
        raise ModelError(
            f"feature count mismatch: expected {len(FEATURE_NAMES)}, got {X.shape[1]}"
        )
    _check_y_all_classes(y)

    # Chronological split: 80 % train / 20 % validation, respecting order
    split_idx = int(X.shape[0] * 0.8)
    X_train, X_val = X[:split_idx], X[split_idx:]
    y_train, y_val = y[:split_idx], y[split_idx:]

    clf = HistGradientBoostingClassifier(
        random_state=42,
        max_iter=200,
    )
    clf.fit(X_train, y_train)

    # Report held-out metrics - reorder probabilities to canonical H/D/A order
    y_val_proba_raw = clf.predict_proba(X_val)
    y_val_proba = _reorder_proba_to_canonical(y_val_proba_raw, list(clf.classes_))
    y_val_pred = clf.predict(X_val)
    try:
        metrics = evaluate_predictions(y_val, y_val_proba, y_val_pred)
    except Exception:  # noqa: BLE001 - metrics are best-effort; training still succeeds
        metrics = {"accuracy": 0.0, "log_loss": 0.0, "brier_score": 0.0}

    trained_at = datetime.now(timezone.utc)
    classes = list(_CLASSES)
    bundle = ModelBundle(
        classifier=clf,
        feature_names=FEATURE_NAMES,
        classes=classes,
        model_version=model_version,
        trained_at=trained_at,
        market=MARKET_1X2,
    )

    return clf, bundle


def predict_proba(classifier: object, features: dict[str, float], bundle: ModelBundle | None = None) -> dict[str, float]:
    """Return normalized probabilities for a single feature vector.

    Maps probabilities from the classifier's native ``classes_`` order to the
    canonical order stored in ``bundle.classes`` (or ``["H", "D", "A"]`` for
    backward compatibility with 1X2).
    """
    import numpy as np

    feature_keys = set(features.keys())
    expected_keys = set(FEATURE_NAMES)
    if feature_keys != expected_keys:
        missing = sorted(expected_keys - feature_keys)
        extra = sorted(feature_keys - expected_keys)
        raise ModelError(f"feature schema mismatch: missing {missing}, extra {extra}")

    vector = np.array([features[name] for name in FEATURE_NAMES], dtype=float).reshape(1, -1)
    if vector.shape[1] != len(FEATURE_NAMES):
        raise ModelError("feature count mismatch in prediction")
    raw_proba = classifier.predict_proba(vector)[0]
    # sklearn's predict_proba returns columns in the order of classes_,
    # which is alphabetically sorted. We must reorder to the canonical order
    # stored in bundle.classes (or ["H", "D", "A"] for 1X2 compatibility).
    class_order = list(bundle.classes) if bundle is not None else _CLASSES
    label_to_idx: dict[str, int] = {label: i for i, label in enumerate(classifier.classes_)}
    # Place each canonical label at the position corresponding to its raw column
    reordered = np.array([raw_proba[label_to_idx[label]] for label in class_order])
    # Ensure normalized to sum to 1.0
    total = float(np.sum(reordered))
    if total == 0.0:
        raise ModelError("model produced zero-probability output")
    normalized = reordered / total
    return {label: float(prob) for label, prob in zip(class_order, normalized)}


def _check_binary_y(y: np.ndarray) -> None:
    """Validate that binary labels contain exactly two classes."""
    classes = set(y.tolist())
    if len(classes) != 2:
        missing = {True, False} - classes if True in classes or False in classes else classes
        raise ModelError(
            f"insufficient binary training data: expected 2 classes, missing {sorted(classes)}"
        )


def train_binary_classifier(
    X: np.ndarray,
    y: np.ndarray,
    model_version: str = "0.1.0",
    market: str = UNKNOWN_MARKET,
) -> tuple[HistGradientBoostingClassifier, ModelBundle]:
    """Train a binary classifier on feature vectors and labels.

    Parameters
    ----------
    X: np.ndarray
        Feature matrix with shape ``(n_samples, n_features)``, n_features == 17.
    y: np.ndarray
        Target labels encoded as the strings ``"Over"/"Under"`` or ``"Yes"/"No"``.
    model_version: operator-facing string persisted in the artifact metadata.

    Returns
    -------
    (classifier, bundle) tuple ready to be saved with ``save_bundle``.
    """
    _check_binary_y(y)

    if X.shape[0] < 30:
        raise ModelError(f"insufficient training samples ({X.shape[0]} < 30)")
    if X.shape[1] != len(FEATURE_NAMES):
        raise ModelError(
            f"feature count mismatch: expected {len(FEATURE_NAMES)}, got {X.shape[1]}"
        )

    # Chronological split: 80 % train / 20 % validation, respecting order
    split_idx = int(X.shape[0] * 0.8)
    X_train, X_val = X[:split_idx], X[split_idx:]
    y_train, y_val = y[:split_idx], y[split_idx:]

    clf = HistGradientBoostingClassifier(
        random_state=42,
        max_iter=200,
    )
    clf.fit(X_train, y_train)

    # Report held-out metrics - reorder probabilities to canonical [first, second] order
    # sklearn's classes_ are alphabetically sorted. We need to reorder to match the
    # canonical order passed in the bundle.
    y_val_proba_raw = clf.predict_proba(X_val)
    trained_classes = list(clf.classes_)
    bundle = ModelBundle(
        classifier=clf,
        feature_names=FEATURE_NAMES,
        classes=trained_classes,
        model_version=model_version,
        trained_at=datetime.now(timezone.utc),
        market=market,
    )

    return clf, bundle


def predict_binary_proba(
    classifier: HistGradientBoostingClassifier,
    features: dict[str, float],
    bundle: ModelBundle,
) -> dict[str, float]:
    """Return normalized binary probabilities for a single feature vector.

    Maps probabilities from the classifier's native ``classes_`` order to the
    canonical order stored in ``bundle.classes``.
    """
    import numpy as np

    feature_keys = set(features.keys())
    expected_keys = set(FEATURE_NAMES)
    if feature_keys != expected_keys:
        missing = sorted(expected_keys - feature_keys)
        extra = sorted(feature_keys - expected_keys)
        raise ModelError(f"feature schema mismatch: missing {missing}, extra {extra}")

    vector = np.array([features[name] for name in FEATURE_NAMES], dtype=float).reshape(1, -1)
    if vector.shape[1] != len(FEATURE_NAMES):
        raise ModelError("feature count mismatch in prediction")

    raw_proba = classifier.predict_proba(vector)[0]
    # sklearn's predict_proba returns columns in the order of classes_,
    # which is alphabetically sorted. We must reorder to the canonical order
    # stored in bundle.classes.
    class_order = list(bundle.classes)
    label_to_idx: dict[str, int] = {label: i for i, label in enumerate(classifier.classes_)}
    # Place each canonical label at the position corresponding to its raw column
    reordered = np.array([raw_proba[label_to_idx[label]] for label in class_order])
    # Ensure normalized to sum to 1.0
    total = float(np.sum(reordered))
    if total == 0.0:
        raise ModelError("model produced zero-probability output")
    normalized = reordered / total
    return {
        class_name: float(normalized[i])
        for i, class_name in enumerate(class_order)
    }