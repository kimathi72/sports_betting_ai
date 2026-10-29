"""Tests for the 1X2 baseline model: training, persistence, and inference.

The model predicts H (home win), D (draw), A (away win) using only pre-kickoff
features. It must:
- Reject insufficient training data.
- Reject unknown feature names / wrong schema.
- Persist and reload artifacts reproducibly.
- Return normalized probabilities that sum to 1.
- Fail clearly when model artifacts are absent.
"""
from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pytest

from ml.app.features import FEATURE_NAMES
from ml.app.model_store import ModelBundle, ModelError, load_bundle, save_bundle
from ml.app.model import BaselineClassifier, train_baseline


def _synthetic_dataset(n_per_class: int = 60) -> tuple[np.ndarray, np.ndarray]:
    rng = np.random.default_rng(42)
    n = n_per_class * 3
    X = np.zeros((n, len(FEATURE_NAMES)), dtype=float)
    y = np.empty(n, dtype=object)
    for label_idx, label in enumerate(["H", "D", "A"]):
        start = label_idx * n_per_class
        end = start + n_per_class
        y[start:end] = label
        for j in range(len(FEATURE_NAMES)):
            if label == "H":
                X[start:end, j] = 2.0 + rng.normal(0, 0.5, n_per_class)
            elif label == "D":
                X[start:end, j] = 1.5 + rng.normal(0, 0.5, n_per_class)
            else:
                X[start:end, j] = 1.0 + rng.normal(0, 0.5, n_per_class)
    return X, y


def test_train_baseline_succeeds_with_enough_data() -> None:
    X, y = _synthetic_dataset(n_per_class=60)
    clf, bundle = train_baseline(X, y)
    assert clf is not None
    assert bundle is not None
    assert bundle.classes == ["H", "D", "A"]


def test_train_baseline_rejects_insufficient_data() -> None:
    X = np.zeros((2, len(FEATURE_NAMES)), dtype=float)
    y = np.array(["H", "A"])
    with pytest.raises(ModelError, match="insufficient"):
        train_baseline(X, y)


def test_train_baseline_rejects_missing_classes() -> None:
    X, y = _synthetic_dataset(n_per_class=60)
    mask = y != "D"
    X_filtered = X[mask]
    y_filtered = y[mask]
    with pytest.raises(ModelError, match="not all three classes"):
        train_baseline(X_filtered, y_filtered)


def test_predict_returns_normalized_probabilities() -> None:
    X, y = _synthetic_dataset(n_per_class=100)
    clf, _ = train_baseline(X, y)
    probs = clf.predict_proba(X[:5])
    assert probs.shape == (5, 3)
    for row in probs:
        assert abs(sum(row) - 1.0) < 1e-6


def test_predict_rejects_wrong_feature_count() -> None:
    X, y = _synthetic_dataset(n_per_class=100)
    clf, _ = train_baseline(X, y)
    from ml.app.model import predict_proba
    extra = {name: 0.0 for name in FEATURE_NAMES}
    extra["extra_feature"] = 0.0
    with pytest.raises(ModelError, match="feature"):
        predict_proba(clf, extra)


def test_save_and_load_roundtrip(tmp_path: Path) -> None:
    X, y = _synthetic_dataset(n_per_class=80)
    clf, bundle = train_baseline(X, y)

    save_path = tmp_path / "model.joblib"
    save_bundle(bundle, save_path)

    loaded = load_bundle(save_path)
    assert loaded.model_version == bundle.model_version
    assert loaded.classes == ["H", "D", "A"]
    assert loaded.feature_names == list(FEATURE_NAMES)

    probs_original = clf.predict_proba(X[:5])
    probs_loaded = loaded.classifier.predict_proba(X[:5])
    np.testing.assert_allclose(probs_original, probs_loaded, atol=1e-9)


def test_load_bundle_missing_file(tmp_path: Path) -> None:
    missing = tmp_path / "does_not_exist.joblib"
    with pytest.raises(ModelError, match="artifact"):
        load_bundle(missing)


def test_load_bundle_tampered_file(tmp_path: Path) -> None:
    (tmp_path / "bad.joblib").write_text("not a model")
    with pytest.raises(ModelError, match="artifact"):
        load_bundle(tmp_path / "bad.joblib")


def test_train_baseline_rejects_unknown_feature_count() -> None:
    X = np.zeros((60, len(FEATURE_NAMES) + 1), dtype=float)
    y = np.array(["H"] * 20 + ["D"] * 20 + ["A"] * 20)
    with pytest.raises(ModelError, match="feature"):
        train_baseline(X, y)


def test_predict_proba_normalizes_and_returns_classes() -> None:
    X, y = _synthetic_dataset(n_per_class=100)
    clf, _ = train_baseline(X, y)
    from ml.app.model import predict_proba
    probs = predict_proba(clf, {name: 1.0 for name in FEATURE_NAMES})
    assert set(probs.keys()) == {"H", "D", "A"}
    assert abs(sum(probs.values()) - 1.0) < 1e-6
    for v in probs.values():
        assert 0.0 <= v <= 1.0


# Class ordering regression tests
# The sklearn classifier internally sorts classes alphabetically: ['A', 'D', 'H']
# but our public contract requires H/D/A ordering.
# These tests verify the correct mapping at every boundary.

def test_classifier_native_classes_order() -> None:
    """HistGradientBoostingClassifier internally sorts classes alphabetically."""
    from sklearn.ensemble import HistGradientBoostingClassifier
    import numpy as np
    X = np.array([[0.0], [1.0], [2.0], [3.0], [4.0], [5.0]])
    y = np.array(["H", "D", "A", "H", "D", "A"])
    clf = HistGradientBoostingClassifier(random_state=42, max_iter=10)
    clf.fit(X, y)
    # sklearn sorts classes alphabetically
    assert list(clf.classes_) == ["A", "D", "H"]


def test_predict_proba_maps_native_to_canonical_order() -> None:
    """predict_proba must reorder from sklearn's native ['A','D','H'] to canonical ['H','D','A']."""
    from ml.app.model import predict_proba, BaselineClassifier
    import numpy as np
    # Create a classifier with known predict_proba output
    clf = BaselineClassifier(random_state=42, max_iter=10)
    # Force classes_ to be the native sklearn order
    clf.classes_ = np.array(["A", "D", "H"])
    
    # Mock predict_proba to return known asymmetric probabilities
    # Column 0 = P(A), Column 1 = P(D), Column 2 = P(H)
    def mock_predict_proba(X):
        return np.array([[0.1, 0.3, 0.6]])  # P(A)=0.1, P(D)=0.3, P(H)=0.6
    
    clf.predict_proba = mock_predict_proba
    
    probs = predict_proba(clf, {name: 0.0 for name in FEATURE_NAMES})
    
    # Canonical H/D/A should map: H=0.6, D=0.3, A=0.1
    assert abs(probs["H"] - 0.6) < 1e-9
    assert abs(probs["D"] - 0.3) < 1e-9
    assert abs(probs["A"] - 0.1) < 1e-9
    assert abs(sum(probs.values()) - 1.0) < 1e-6


def test_metrics_log_loss_with_known_vectors() -> None:
    """Log loss verified against independent calculation with canonical H/D/A order."""
    from ml.app.metrics import log_loss
    import numpy as np
    
    # True labels in canonical order H=0, D=1, A=2
    y_true = np.array(["H", "D", "A", "H", "A"])
    
    # Probabilities in canonical H/D/A column order
    y_proba = np.array([
        [0.8, 0.1, 0.1],  # H: high prob for H
        [0.1, 0.8, 0.1],  # D: high prob for D
        [0.1, 0.1, 0.8],  # A: high prob for A
        [0.7, 0.2, 0.1],  # H
        [0.1, 0.2, 0.7],  # A
    ])
    
    # Expected: mean of -log(p_true) = (-log(0.8) -log(0.8) -log(0.8) -log(0.7) -log(0.7)) / 5
    expected = (-(np.log(0.8) + np.log(0.8) + np.log(0.8) + np.log(0.7) + np.log(0.7))) / 5
    result = log_loss(y_true, y_proba)
    assert abs(result - expected) < 1e-9


def test_metrics_brier_score_with_known_vectors() -> None:
    """Brier score verified against independent calculation with canonical H/D/A order."""
    from ml.app.metrics import brier_score
    import numpy as np
    
    y_true = np.array(["H", "D", "A"])
    
    # Probabilities in canonical H/D/A column order
    y_proba = np.array([
        [1.0, 0.0, 0.0],  # perfect H
        [0.0, 1.0, 0.0],  # perfect D
        [0.0, 0.0, 1.0],  # perfect A
    ])
    
    # Brier = mean of sum((one_hot - proba)^2) = 0 for perfect predictions
    result = brier_score(y_true, y_proba)
    assert abs(result - 0.0) < 1e-9
    
    # Another case: uniform probabilities
    y_proba2 = np.array([
        [1/3, 1/3, 1/3],
        [1/3, 1/3, 1/3],
        [1/3, 1/3, 1/3],
    ])
    # Brier for uniform = mean of (2/3)^2 + (1/3)^2 + (1/3)^2 = 2/3 per sample
    result2 = brier_score(y_true, y_proba2)
    expected2 = 2.0 / 3.0
    assert abs(result2 - expected2) < 1e-9


def test_saved_artifact_preserves_canonical_classes() -> None:
    """Saved model bundle must store canonical classes ['H','D','A']."""
    from ml.app.model import train_baseline
    from ml.app.model_store import save_bundle, load_bundle
    from pathlib import Path
    import tempfile
    
    X, y = _synthetic_dataset(n_per_class=60)
    clf, bundle = train_baseline(X, y)
    
    with tempfile.TemporaryDirectory() as tmp:
        save_path = Path(tmp) / "model.joblib"
        save_bundle(bundle, save_path)
        
        loaded = load_bundle(save_path)
        assert loaded.classes == ["H", "D", "A"]


def test_end_to_end_probability_mapping() -> None:
    """Full pipeline: train -> save -> load -> predict uses canonical H/D/A."""
    from ml.app.model import train_baseline, predict_proba
    from ml.app.model_store import save_bundle, load_bundle
    from pathlib import Path
    import tempfile
    import numpy as np
    
    # Train with data where we can predict the class
    # Use highly separable features: high values for H, low for A
    rng = np.random.default_rng(42)
    X = np.zeros((60, 17))
    y = np.empty(60, dtype=object)
    
    # 20 samples for H: very high features
    X[:20, :] = 100.0 + rng.normal(0, 1.0, (20, 17))
    y[:20] = "H"
    
    # 20 samples for D: moderate features
    X[20:40, :] = 50.0 + rng.normal(0, 1.0, (20, 17))
    y[20:40] = "D"
    
    # 20 samples for A: very low features
    X[40:60, :] = 0.0 + rng.normal(0, 1.0, (20, 17))
    y[40:60] = "A"
    
    clf, bundle = train_baseline(X, y)
    
    # Check native classifier order
    assert list(clf.classes_) == ["A", "D", "H"]
    
    # Bundle stores canonical order
    assert bundle.classes == ["H", "D", "A"]
    
    # Save and reload
    with tempfile.TemporaryDirectory() as tmp:
        save_path = Path(tmp) / "model.joblib"
        save_bundle(bundle, save_path)
        loaded = load_bundle(save_path)
        assert loaded.classes == ["H", "D", "A"]
        
        # Predict with loaded model - should use canonical mapping
        probs = predict_proba(loaded.classifier, {name: 100.0 for name in FEATURE_NAMES})
        # High home features should predict H with high probability
        # In canonical order: H prob should be highest
        assert probs["H"] > probs["D"]
        assert probs["H"] > probs["A"]
        
        # Predict with low features -> A should be highest
        probs_low = predict_proba(loaded.classifier, {name: 0.0 for name in FEATURE_NAMES})
        assert probs_low["A"] > probs_low["D"]
        assert probs_low["A"] > probs_low["H"]


def test_train_baseline_metrics_use_canonical_order() -> None:
    """train_baseline must compute held-out metrics with canonical H/D/A column order."""
    from ml.app.model import train_baseline
    import numpy as np
    
    # Use synthetic data where the correct column ordering matters.
    # Features: column 0 = home_last5_points (high for H)
    # Train: H has high feature 0, D medium, A low
    X = np.zeros((60, len(FEATURE_NAMES)))
    y = np.empty(60, dtype=object)
    X[:20, 0] = 100.0
    y[:20] = "H"
    X[20:40, 0] = 50.0
    y[20:40] = "D"
    X[40:60, 0] = 0.0
    y[40:60] = "A"
    
    clf, bundle = train_baseline(X, y)
    
    # The classifier internally sorts as ['A', 'D', 'H'], so predict_proba columns
    # are native order A/D/H. train_baseline must reorder to H/D/A before metrics.
    # Verify bundle classes are canonical:
    assert bundle.classes == ["H", "D", "A"]
    
    # Verify metrics are finite and plausible (not garbage from wrong column order)
    from ml.app.metrics import _reorder_proba_to_canonical
    split_idx = int(X.shape[0] * 0.8)
    X_val, y_val = X[split_idx:], y[split_idx:]
    y_val_proba_raw = clf.predict_proba(X_val)
    y_val_proba_canonical = _reorder_proba_to_canonical(y_val_proba_raw, list(clf.classes_))
    
    # Verify no zero probabilities in true class positions (canonical ordering)
    true_class_idx = np.array([["H", "D", "A"].index(c) for c in y_val])
    true_probs = y_val_proba_canonical[np.arange(len(y_val)), true_class_idx]
    assert np.all(true_probs > 0.0), "Canonical reordered probabilities must be >0 for true classes"