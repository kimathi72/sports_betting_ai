"""Market contracts for artifacts and live inference.

The unit suites prove each market trains and predicts. This file proves the
*contract between them*: that an artifact says which market it is, that inference
refuses an artifact claiming to be a different market, and that double chance is
never served as an independent model.

A mislabelled artifact is not cosmetic. `market` is what an operator reads to
decide which file to roll back, and what a future loader would trust when
choosing an artifact per market. "Over/Under model, labelled 1x2" is exactly the
kind of thing that survives silently until a rollback picks the wrong file.
"""
from __future__ import annotations

import numpy as np
import pytest

from ml.app.model import train_binary_classifier
from ml.app.model_store import (
    ALL_MARKETS,
    FEATURE_NAMES,
    MARKET_1X2,
    MARKET_BTTS,
    MARKET_DOUBLE_CHANCE,
    MARKET_OVER_UNDER,
    ModelBundle,
    ModelError,
    load_bundle,
    save_bundle,
)


def _synthetic(n: int = 120, classes=("H", "D", "A")):
    rng = np.random.default_rng(0)
    X = rng.normal(size=(n, len(FEATURE_NAMES)))
    y = np.array([classes[i % len(classes)] for i in range(n)])
    return X, y


# --- training records its own market ----------------------------------------

def test_binary_training_can_declare_its_market() -> None:
    X, y = _synthetic(classes=("Over", "Under"))

    _, bundle = train_binary_classifier(X, y, model_version="t1", market=MARKET_OVER_UNDER)

    assert bundle.market == MARKET_OVER_UNDER


def test_binary_training_defaults_to_no_market_rather_than_lying() -> None:
    """Omitting the market must not silently claim 1x2."""
    X, y = _synthetic(classes=("Yes", "No"))

    _, bundle = train_binary_classifier(X, y)

    assert bundle.market != MARKET_1X2


def test_multiclass_training_keeps_the_1x2_default() -> None:
    from ml.app.model import train_baseline

    X, y = _synthetic()

    _, bundle = train_baseline(X, y)

    assert bundle.market == MARKET_1X2


# --- round trip -------------------------------------------------------------

@pytest.mark.parametrize(
    "market,classes",
    [
        (MARKET_1X2, ("H", "D", "A")),
        (MARKET_OVER_UNDER, ("Over", "Under")),
        (MARKET_BTTS, ("Yes", "No")),
    ],
)
def test_saved_artifact_round_trips_its_market_and_version(tmp_path, market, classes) -> None:
    X, y = _synthetic(classes=classes)

    if len(classes) == 2:
        _, bundle = train_binary_classifier(X, y, model_version="v-test", market=market)
    else:
        from ml.app.model import train_baseline

        _, bundle = train_baseline(X, y, model_version="v-test")
        bundle.market = market

    path = tmp_path / f"model_{market}.joblib"
    save_bundle(bundle, path)

    loaded = load_bundle(path)
    assert loaded.market == market
    assert loaded.model_version == "v-test"
    assert set(loaded.classes) == set(classes)


# --- every supported market is accounted for --------------------------------

def test_supported_markets_exactly_cover_the_product_contract() -> None:
    assert set(ALL_MARKETS) == {
        MARKET_1X2,
        MARKET_OVER_UNDER,
        MARKET_BTTS,
        MARKET_DOUBLE_CHANCE,
    }


def test_double_chance_is_a_derived_market_not_a_trained_one() -> None:
    """There must be no double-chance artifact path: it is projected from 1X2."""
    from ml.app.model_store import DERIVED_MARKETS, TRAINED_MARKETS

    assert MARKET_DOUBLE_CHANCE in DERIVED_MARKETS
    assert MARKET_DOUBLE_CHANCE not in TRAINED_MARKETS
    assert set(TRAINED_MARKETS) == {MARKET_1X2, MARKET_OVER_UNDER, MARKET_BTTS}


def test_double_chance_probabilities_are_projections_of_1x2() -> None:
    from ml.app.features import double_chance_probabilities

    probs_1x2 = {"H": 0.5, "D": 0.3, "A": 0.2}
    dc = double_chance_probabilities(probs_1x2)

    assert dc["1X"] == pytest.approx(0.8)
    assert dc["X2"] == pytest.approx(0.5)
    assert dc["12"] == pytest.approx(0.7)
    # Overlapping events: the three sum to 2 by construction, not to 1.
    assert sum(dc.values()) == pytest.approx(2.0)


@pytest.mark.parametrize(
    "probs",
    [
        {"H": 1.0, "D": 0.0, "A": 0.0},
        {"H": 0.0, "D": 1.0, "A": 0.0},
        {"H": 0.0, "D": 0.0, "A": 1.0},
        {"H": 0.34, "D": 0.33, "A": 0.33},
    ],
)
def test_double_chance_invariants_hold_for_any_valid_1x2(probs) -> None:
    from ml.app.features import double_chance_probabilities

    dc = double_chance_probabilities(probs)

    assert all(0.0 <= v <= 1.0 for v in dc.values())
    # Each double chance is the complement of the outcome it excludes.
    assert dc["1X"] + probs["A"] == pytest.approx(1.0)
    assert dc["X2"] + probs["H"] == pytest.approx(1.0)
    assert dc["12"] + probs["D"] == pytest.approx(1.0)
    assert sum(dc.values()) == pytest.approx(2.0)


# --- inference refuses a mismatched artifact --------------------------------

def test_inference_refuses_a_boxing_a_1x2_artifact_as_btts(tmp_path) -> None:
    """A three-class 1X2 artifact must never be served as a binary market."""
    from ml.app import main as service
    from ml.app.model import train_baseline

    X, y = _synthetic()
    _, bundle = train_baseline(X, y)
    path = tmp_path / "real_1x2.joblib"
    save_bundle(bundle, path)  # market == 1x2, classes == H/D/A

    service.set_artifact_path(MARKET_BTTS, path)
    service.load_model(MARKET_BTTS)

    with pytest.raises(Exception) as excinfo:
        service._load_model(MARKET_BTTS)

    assert "market" in str(excinfo.value).lower()


def test_a_correctly_labelled_binary_artifact_is_served(tmp_path) -> None:
    from ml.app import main as service

    X, y = _synthetic(classes=("Yes", "No"))
    _, bundle = train_binary_classifier(X, y, market=MARKET_BTTS)
    path = tmp_path / "btts.joblib"
    save_bundle(bundle, path)

    service.set_artifact_path(MARKET_BTTS, path)
    service.load_model(MARKET_BTTS)

    assert service._load_model(MARKET_BTTS).market == MARKET_BTTS


def test_a_legacy_binary_artifact_stamped_1x2_is_tolerated(tmp_path) -> None:
    """Artifacts written before the fix carry market='1x2'.

    A two-class model without H/D/A cannot be 1X2, so the label is provably a
    default. Refusing to serve it would break a working deployment over a
    metadata-only defect; relabelling it silently would hide the defect. It is
    served, and the mismatch is logged for the operator to fix by retraining.
    """
    from ml.app import main as service

    X, y = _synthetic(classes=("Over", "Under"))
    _, bundle = train_binary_classifier(X, y)  # market defaults to UNKNOWN
    bundle.market = MARKET_1X2  # simulate the legacy stamp
    path = tmp_path / "legacy_ou.joblib"
    save_bundle(bundle, path)

    service.set_artifact_path(MARKET_OVER_UNDER, path)
    service.load_model(MARKET_OVER_UNDER)

    loaded = service._load_model(MARKET_OVER_UNDER)
    assert set(loaded.classes) == {"Over", "Under"}


def test_a_binary_artifact_of_the_WRONG_binary_market_is_refused(tmp_path) -> None:
    from ml.app import main as service

    X, y = _synthetic(classes=("Yes", "No"))
    _, bundle = train_binary_classifier(X, y, market=MARKET_BTTS)
    path = tmp_path / "btts.joblib"
    save_bundle(bundle, path)

    service.set_artifact_path(MARKET_OVER_UNDER, path)
    service.load_model(MARKET_OVER_UNDER)

    with pytest.raises(Exception) as excinfo:
        service._load_model(MARKET_OVER_UNDER)

    assert "market" in str(excinfo.value).lower()


# --- double chance is SERVED from the 1X2 model -----------------------------

def _feature_request() -> dict:
    return {name: 0.0 for name in FEATURE_NAMES}


def _real_1x2_bundle(tmp_path):
    from ml.app.model import train_baseline

    X, y = _synthetic()
    _, bundle = train_baseline(X, y, model_version="dc-serve")
    path = tmp_path / "model_1x2.joblib"
    save_bundle(bundle, path)
    return path


def test_double_chance_is_served_from_the_1x2_artifact(tmp_path) -> None:
    """There is no double_chance artifact, and there must never be one.

    Serving double chance used to load the ``double_chance`` artifact path,
    which does not exist, so the market returned 503 and only appeared to work
    in tests that injected an artifact for every market. Projection from 1X2 is
    the contract: same model, same features, derived probabilities.
    """
    from ml.app import main as service

    path = _real_1x2_bundle(tmp_path)
    service.set_artifact_path(MARKET_1X2, path)

    response = service.predict_market(MARKET_DOUBLE_CHANCE, _request_obj())

    assert set(response.probabilities) == {"1X", "X2", "12"}
    assert response.model_version == "dc-serve"


def test_double_chance_equals_its_1x2_projection_exactly(tmp_path) -> None:
    from ml.app import main as service

    path = _real_1x2_bundle(tmp_path)
    service.set_artifact_path(MARKET_1X2, path)

    base = service.predict_market(MARKET_1X2, _request_obj())
    dc = service.predict_market(MARKET_DOUBLE_CHANCE, _request_obj())

    p = base.probabilities
    assert dc.probabilities["1X"] == pytest.approx(p["H"] + p["D"])
    assert dc.probabilities["X2"] == pytest.approx(p["D"] + p["A"])
    assert dc.probabilities["12"] == pytest.approx(p["H"] + p["A"])


def test_double_chance_is_selected_by_the_query_parameter(tmp_path) -> None:
    """The market travels in the QUERY STRING, never in the body.

    An earlier schema accepted an optional `market` body field, which allowed the
    path and the body to disagree about which market was being predicted. The body
    now forbids extra keys, so the market has exactly one source.
    """
    from ml.app import main as service

    path = _real_1x2_bundle(tmp_path)
    service.set_artifact_path(MARKET_1X2, path)

    request = service.PredictRequest(**_feature_request())
    response = service.predict(request, market=MARKET_DOUBLE_CHANCE)

    assert set(response.probabilities) == {"1X", "X2", "12"}


def test_the_body_cannot_carry_a_market_field(tmp_path) -> None:
    from pydantic import ValidationError

    from ml.app import main as service

    with pytest.raises(ValidationError):
        service.PredictRequest(market="btts", **_feature_request())


def _request_obj():
    from ml.app import main as service

    return service.PredictRequest(**_feature_request())


def test_no_double_chance_artifact_path_is_requested() -> None:
    """Guard against reintroducing the bug: the derived market must map to 1X2."""
    from ml.app import main as service

    assert service._artifact_market(MARKET_DOUBLE_CHANCE) == MARKET_1X2
    assert service._artifact_market(MARKET_BTTS) == MARKET_BTTS
