"""Provenance for the model artifact actually used to answer a request.

THE PROBLEM
-----------
Rails stores `model_freeze_digest` against every prediction. Until now the ML service
returned nothing, so the column would have been permanently NULL. The tempting fix is
to return the digest from the freeze record — but that says "a frozen generation
exists", not "this process loaded it". If an artifact were replaced after the freeze,
a hardcoded digest would confidently attribute probabilities to a model that did not
produce them.

WHAT THIS DOES
--------------
The digest is computed from the artifact's BYTES at load time, then checked against
the freeze record:

  bytes match freeze  -> verified; the digest is returned
  bytes differ        -> checksum_mismatch; NO digest is returned
  not in the freeze   -> not_in_freeze; NO digest is returned
  no freeze record    -> no_freeze_record; NO digest is returned
  file absent         -> artifact_missing; NO digest is returned

Downstream, Rails therefore records NULL for anything unverified, which its
eligibility check already treats as "not attributable". Failing closed is the whole
point: an honest NULL beats a plausible-looking constant.

This module deliberately reuses `model_freeze.sha256_of` instead of re-implementing
the hash, so the two can never disagree about how a checksum is computed.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

# Absolute, matching every other module in this package (`main.py` imports
# `ml.app.features`, `ml.app.model_store`, ...). The container runs
# `uvicorn ml.app.main:app` with PYTHONPATH=/app, so the importable name is
# `ml.app`, not `app`. A bare `from app.model_freeze import ...` worked under
# pytest (which puts `ml/` on sys.path) and crashed the container at boot with
# ModuleNotFoundError — a test-only import path is not a deployment path.
from ml.app.model_freeze import sha256_of

# Stable marker for "no verified provenance". Callers may key on it, so it is a
# documented constant rather than a literal scattered through the codebase.
PROVENANCE_UNAVAILABLE = "unavailable"

# Reasons a digest is not offered. Kept in the response so a caller can distinguish a
# tampered artifact from an old service that simply does not report provenance.
REASON_VERIFIED = "verified"
REASON_CHECKSUM_MISMATCH = "checksum_mismatch"
REASON_NOT_IN_FREEZE = "not_in_freeze"
REASON_NO_FREEZE = "no_freeze_record"
REASON_MISSING = "artifact_missing"


@dataclass(frozen=True)
class FreezeRecord:
    """The parts of a freeze document inference needs."""

    protocol_version: str | None
    protocol_digest: str | None
    artifacts: Mapping[str, Mapping[str, Any]]

    @property
    def digest(self) -> str | None:
        return self.protocol_digest


def load_freeze(path: str | Path | None) -> FreezeRecord | None:
    """Load a freeze document, or None when there is none.

    A malformed freeze raises rather than silently yielding "no provenance": a
    corrupt record is a deployment problem somebody must see.
    """
    if path is None:
        return None

    path = Path(path)
    if not path.exists():
        return None

    payload = json.loads(path.read_text())
    if not isinstance(payload, dict) or "artifacts" not in payload:
        raise ValueError(f"{path} is not a freeze record (no 'artifacts' key)")

    return FreezeRecord(
        protocol_version=payload.get("protocol_version"),
        protocol_digest=payload.get("protocol_digest"),
        artifacts=payload["artifacts"],
    )


def digest_for_artifact(path: str | Path) -> str | None:
    """SHA-256 of the artifact bytes, or None when it cannot be read."""
    path = Path(path)
    if not path.is_file():
        return None
    return sha256_of(path)


@dataclass(frozen=True)
class ArtifactProvenance:
    """What can honestly be said about the artifact behind a prediction."""

    digest: str | None
    freeze_digest: str | None
    verified: bool
    reason: str
    feature_version: str | None = None

    @classmethod
    def for_artifact(cls, path: str | Path, *, freeze: FreezeRecord | None) -> "ArtifactProvenance":
        path = Path(path)
        actual = digest_for_artifact(path)

        if actual is None:
            return cls(digest=None, freeze_digest=None, verified=False, reason=REASON_MISSING)

        if freeze is None:
            return cls(digest=actual, freeze_digest=None, verified=False, reason=REASON_NO_FREEZE)

        recorded = freeze.artifacts.get(path.name)
        if recorded is None:
            return cls(digest=actual, freeze_digest=None, verified=False, reason=REASON_NOT_IN_FREEZE)

        expected = recorded.get("sha256")
        if expected != actual:
            # The artifact changed after the freeze. It is emphatically NOT the frozen
            # generation, so no digest is offered even though one was computed.
            return cls(
                digest=actual,
                freeze_digest=None,
                verified=False,
                reason=REASON_CHECKSUM_MISMATCH,
            )

        return cls(
            digest=actual,
            freeze_digest=freeze.digest,
            verified=True,
            reason=REASON_VERIFIED,
            feature_version=recorded.get("feature_version"),
        )

    def to_response_fields(self) -> dict[str, Any]:
        """Fields added to the prediction response.

        Only a verified artifact offers a digest. Everything else returns None plus a
        status explaining why, so the caller is never left guessing whether a missing
        field means "old service" or "wrong artifact".

        `feature_version` is deliberately NOT included: the endpoint already supplies
        it, and returning it here would collide with that keyword argument. The
        provenance exists to identify WHICH artifact ran, not to restate its schema.
        """
        return {
            "model_freeze_digest": self.digest if self.verified else None,
            "artifact_sha256": self.digest,
            "provenance_status": self.reason,
        }
