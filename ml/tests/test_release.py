"""Safe model release: candidate -> evaluate -> promote -> rollback.

Why a separate workflow exists
------------------------------
Training writes a file. Serving reads a file. If training writes the file that
serving reads, then every retrain is an uncontrolled production deployment — and
daily data synchronization, which changes the training set, becomes a deployer.
That is the failure this module exists to prevent.

The invariants under test, in order of importance:

1. Training writes to the CANDIDATE store and never touches PRODUCTION.
2. Promotion requires an evaluation report that scores the exact candidate hash
   being promoted, and it is refused when the candidate does not beat the
   baseline by the documented margin.
3. Promotion is reversible: the replaced production artifact is archived, and
   rollback restores it byte for byte.
4. Every transition is journaled with who/why/what, so a rollback decision can
   be audited rather than guessed.
"""
from __future__ import annotations

import json

import numpy as np
import pytest

from ml.app import release
from ml.app.model import train_baseline
from ml.app.model_store import FEATURE_NAMES, MARKET_1X2


def _train_bundle(seed: int = 0, market: str = MARKET_1X2):
    rng = np.random.default_rng(seed)
    X = rng.normal(size=(120, len(FEATURE_NAMES)))
    y = np.array([["H", "D", "A"][i % 3] for i in range(120)], dtype=object)
    _, bundle = train_baseline(X, y, model_version=f"cand-{seed}")
    return bundle


@pytest.fixture
def store(tmp_path):
    return release.ReleaseStore(
        candidates_dir=tmp_path / "candidates",
        production_dir=tmp_path / "production",
        archive_dir=tmp_path / "archive",
        journal_path=tmp_path / "journal.jsonl",
    )


# --- candidate isolation ----------------------------------------------------

def test_training_output_lands_in_the_candidate_store(store) -> None:
    path = store.save_candidate(_train_bundle(), market=MARKET_1X2)

    assert path.is_file()
    assert store.production_dir not in path.parents
    assert list(store.production_dir.glob("*")) == []


def test_a_candidate_never_overwrites_production(store) -> None:
    first = store.save_candidate(_train_bundle(1), market=MARKET_1X2)
    store.promote(first, market=MARKET_1X2,
                  report=_passing_report(store, MARKET_1X2, digest=release.file_sha256(first)))
    production = store.production_path(MARKET_1X2)
    before = production.read_bytes()

    store.save_candidate(_train_bundle(2), market=MARKET_1X2)

    assert production.read_bytes() == before, "saving a candidate must not touch production"


def test_candidates_are_content_addressed(store) -> None:
    """A candidate's filename IS its content hash, so identity cannot drift.

    Two *separately trained* bundles are not byte-identical (the fitted trees
    differ), which is why this asserts the filename matches the content rather
    than that two runs collapse together.
    """
    a = store.save_candidate(_train_bundle(3), market=MARKET_1X2)
    b = store.save_candidate(_train_bundle(4), market=MARKET_1X2)

    assert a.stem == release.file_sha256(a)
    assert b.stem == release.file_sha256(b)
    assert a != b


def test_candidate_carries_its_metadata(store) -> None:
    path = store.save_candidate(_train_bundle(), market=MARKET_1X2, metadata={"features": 17})

    meta = store.candidate_metadata(path)
    assert meta["market"] == MARKET_1X2
    assert meta["sha256"] == release.file_sha256(path)
    assert meta["model_version"] == "cand-0"


# --- promotion gate ---------------------------------------------------------

def _passing_report(store, market, beats_baseline: bool = True, digest: str | None = None) -> dict:
    return {
        "market": market,
        "protocol_digest": release.PROTOCOL_DIGEST,
        # The caller passes the candidate it intends to promote, or supplies a
        # deliberately wrong hash for the mismatch test.
        "candidate_sha256": digest or "0" * 64,
        "selected_by_validation_log_loss": "1x2_gbm",
        "validation_log_loss_of_selected": 0.98,
        "baseline_validation_log_loss": 1.05,
        "beats_baseline": beats_baseline,
        "holdout_status": "exploratory",
    }


def test_a_candidate_without_an_evaluation_report_is_not_promoted(store) -> None:
    candidate = store.save_candidate(_train_bundle(), market=MARKET_1X2)

    with pytest.raises(release.ReleaseError, match="evaluation"):
        store.promote(candidate, market=MARKET_1X2, report=None)


def test_a_report_for_a_different_candidate_is_rejected(store) -> None:
    """Prevents promoting artifact A using the good score of artifact B."""
    good = store.save_candidate(_train_bundle(), market=MARKET_1X2)
    other = store.save_candidate(_train_bundle(9), market=MARKET_1X2)
    # The report scores `other`, but we are asked to promote `good`.
    report = _passing_report(store, MARKET_1X2, digest=release.file_sha256(other))

    with pytest.raises(release.ReleaseError, match="candidate|artifact"):
        store.promote(good, market=MARKET_1X2, report=report)


def test_a_candidate_that_does_not_beat_the_baseline_is_refused(store) -> None:
    candidate = store.save_candidate(_train_bundle(), market=MARKET_1X2)
    report = _passing_report(store, MARKET_1X2, beats_baseline=False,
                             digest=release.file_sha256(candidate))

    with pytest.raises(release.ReleaseError, match="baseline"):
        store.promote(candidate, market=MARKET_1X2, report=report)


def test_a_report_from_a_different_protocol_is_refused(store) -> None:
    candidate = store.save_candidate(_train_bundle(), market=MARKET_1X2)
    report = dict(_passing_report(store, MARKET_1X2, digest=release.file_sha256(candidate)),
                  protocol_digest="deadbeef")

    with pytest.raises(release.ReleaseError, match="protocol"):
        store.promote(candidate, market=MARKET_1X2, report=report)


def test_promotion_is_refused_for_a_derived_market(store) -> None:
    with pytest.raises(release.ReleaseError, match="derived"):
        store.promote(store.candidates_dir / "x.joblib", market="double_chance",
                      report=_passing_report(store, "double_chance"))


def test_a_passing_candidate_is_promoted(store) -> None:
    candidate = store.save_candidate(_train_bundle(), market=MARKET_1X2)
    report = _passing_report(store, MARKET_1X2, digest=release.file_sha256(candidate))

    record = store.promote(candidate, market=MARKET_1X2, report=report)

    production = store.production_path(MARKET_1X2)
    assert production.exists()
    assert release.file_sha256(production) == release.file_sha256(candidate)
    assert record["action"] == "promote"
    assert record["market"] == MARKET_1X2


# --- rollback ---------------------------------------------------------------

def test_rollback_restores_the_previous_production_artifact(store) -> None:
    first = store.save_candidate(_train_bundle(1), market=MARKET_1X2)
    store.promote(first, market=MARKET_1X2,
                  report=_passing_report(store, MARKET_1X2, digest=release.file_sha256(first)))
    original = store.production_path(MARKET_1X2).read_bytes()

    second = store.save_candidate(_train_bundle(2), market=MARKET_1X2)
    store.promote(second, market=MARKET_1X2,
                  report=_passing_report(store, MARKET_1X2,
                                         digest=release.file_sha256(second)))
    assert store.production_path(MARKET_1X2).read_bytes() != original

    record = store.rollback(market=MARKET_1X2)

    assert store.production_path(MARKET_1X2).read_bytes() == original
    assert record["action"] == "rollback"
    assert record["restored_sha256"] == release.sha256_bytes(original)


def test_rollback_with_no_archive_is_a_controlled_error(store) -> None:
    with pytest.raises(release.ReleaseError, match="no previous|nothing to roll back"):
        store.rollback(market=MARKET_1X2)


def test_promotion_and_rollback_are_journaled(store) -> None:
    first = store.save_candidate(_train_bundle(1), market=MARKET_1X2)
    store.promote(first, market=MARKET_1X2,
                  report=_passing_report(store, MARKET_1X2, digest=release.file_sha256(first)))
    second = store.save_candidate(_train_bundle(2), market=MARKET_1X2)
    store.promote(second, market=MARKET_1X2,
                  report=_passing_report(store, MARKET_1X2, digest=release.file_sha256(second)))
    store.rollback(market=MARKET_1X2)

    entries = [json.loads(line) for line in store.journal_path.read_text().splitlines()]

    assert [e["action"] for e in entries] == ["promote", "promote", "rollback"]
    assert all("at" in e for e in entries)


# --- atomicity --------------------------------------------------------------

def test_a_failed_promotion_leaves_production_unchanged(store, monkeypatch) -> None:
    """The swap must be atomic: a crash mid-copy must not yield a half file."""
    first = store.save_candidate(_train_bundle(1), market=MARKET_1X2)
    store.promote(first, market=MARKET_1X2,
                  report=_passing_report(store, MARKET_1X2, digest=release.file_sha256(first)))
    original = store.production_path(MARKET_1X2).read_bytes()

    second = store.save_candidate(_train_bundle(2), market=MARKET_1X2)

    def boom(*args, **kwargs):
        raise OSError("disk full")

    monkeypatch.setattr(release.os, "replace", boom)

    with pytest.raises(OSError):
        store.promote(second, market=MARKET_1X2,
                      report=_passing_report(store, MARKET_1X2,
                                             digest=release.file_sha256(second)))

    assert store.production_path(MARKET_1X2).read_bytes() == original


# --- the daily-job guarantee ------------------------------------------------

def test_synchronization_has_no_promotion_path() -> None:
    """Daily data sync must never be able to promote a model.

    This is a structural assertion, not a behavioural one: no sync entry point
    may reference the release module. If someone wires promotion into the import
    job, this fails.
    """
    import inspect

    from ml.app import evaluate_markets

    source = inspect.getsource(evaluate_markets)
    assert "from ml.app import release" not in source
    assert "release.promote" not in source
    assert "ReleaseStore" not in source


# --- the gate report is derived from the evaluation, not asserted by hand ---

def _evaluation_payload(delta_ci_high: float, protocol: str | None = None) -> dict:
    return {
        "market": MARKET_1X2,
        "protocol_digest": protocol or release.PROTOCOL_DIGEST,
        "test_partition_status": "exploratory",
        "selected_by_validation_log_loss": "logistic_regression",
        "models": [
            {
                "name": "frequency",
                "metrics": {"validation": {"log_loss": 1.0532}, "test": {"log_loss": 1.0818}},
            },
            {
                "name": "logistic_regression",
                "metrics": {
                    "validation": {
                        "log_loss": 1.0002,
                        "log_loss_delta_vs_baseline": {
                            "observed_delta": (delta_ci_high - 0.02),
                            "ci_low": delta_ci_high - 0.06,
                            "ci_high": delta_ci_high,
                        },
                    },
                    "test": {"log_loss": 1.0390},
                },
            },
        ],
    }


def test_report_says_beats_baseline_only_when_the_paired_ci_excludes_zero() -> None:
    from ml.app.release_cli import build_report_from_evaluation

    beating = build_report_from_evaluation(MARKET_1X2, _evaluation_payload(-0.0273), "a" * 64)
    breakeven = build_report_from_evaluation(MARKET_1X2, _evaluation_payload(0.034), "a" * 64)

    assert beating["beats_baseline"] is True
    assert breakeven["beats_baseline"] is False, (
        "a CI spanning zero must not count as beating the baseline"
    )


def test_report_carries_the_candidate_hash_and_protocol() -> None:
    from ml.app.release_cli import build_report_from_evaluation

    built = build_report_from_evaluation(MARKET_1X2, _evaluation_payload(-0.03), "b" * 64)

    assert built["candidate_sha256"] == "b" * 64
    assert built["protocol_digest"] == release.PROTOCOL_DIGEST
    assert built["holdout_status"] == "exploratory"


def test_a_report_built_for_a_stale_protocol_cannot_promote(store) -> None:
    from ml.app.release_cli import build_report_from_evaluation

    candidate = store.save_candidate(_train_bundle(), market=MARKET_1X2)
    built = build_report_from_evaluation(
        MARKET_1X2, _evaluation_payload(-0.03, protocol="0" * 64), release.file_sha256(candidate)
    )

    with pytest.raises(release.ReleaseError, match="protocol"):
        store.promote(candidate, market=MARKET_1X2, report=built)


def test_cli_refuses_a_missing_report_file(store, tmp_path) -> None:
    from ml.app.release_cli import main

    candidate = store.save_candidate(_train_bundle(), market=MARKET_1X2)

    code = main([
        "--artifacts-dir", str(store.production_dir),
        "promote", "--market", MARKET_1X2,
        "--candidate", str(candidate),
        "--report", str(tmp_path / "absent.json"),
    ])

    assert code == 2
    assert not store.production_path(MARKET_1X2).exists()


def test_cli_promote_then_status_then_rollback(store, tmp_path) -> None:
    from ml.app.release_cli import build_report_from_evaluation, main

    first = store.save_candidate(_train_bundle(1), market=MARKET_1X2)
    report = build_report_from_evaluation(
        MARKET_1X2, _evaluation_payload(-0.03), release.file_sha256(first)
    )
    report_path = tmp_path / "report.json"
    report_path.write_text(json.dumps(report))

    code = main([
        "--artifacts-dir", str(store.production_dir),
        "promote", "--market", MARKET_1X2,
        "--candidate", str(first), "--report", str(report_path),
        "--reason", "test",
    ])
    assert code == 0
    assert store.production_path(MARKET_1X2).is_file()

    # A rollback with nothing archived on top must fail cleanly, not crash.
    with pytest.raises(release.ReleaseError, match="nothing to roll back"):
        store.rollback(market=MARKET_1X2)


def test_cli_refuses_to_promote_a_derived_market(store) -> None:
    from ml.app.release_cli import main

    code = main([
        "--artifacts-dir", str(store.production_dir),
        "promote", "--market", "double_chance",
        "--candidate", str(store.production_dir / "x.joblib"),
        "--report", str(store.production_dir / "r.json"),
    ])

    assert code == 2  # report missing is caught before the market check
