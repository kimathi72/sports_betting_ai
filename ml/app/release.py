"""Safe model release: candidate store, gated promotion, reversible rollback.

THE PROBLEM THIS SOLVES
-----------------------
Training and serving both touch a file. If training writes the file that serving
reads, every retrain is an uncontrolled production deployment — and daily data
synchronization, which changes the training set, becomes a deployer. A failed
experiment would silently replace a working model at 06:00 and nobody would know
until the predictions were wrong.

THE FIVE SEPARATE STEPS
-----------------------
1. **Train** -> writes only to the CANDIDATE store
   (``candidates/<market>/<sha256>.joblib``). Content-addressed, so a candidate
   can never overwrite another and its identity is its content.
2. **Evaluate** -> ``ml.app.evaluate_markets`` scores it. It does not know this
   module exists, and a test asserts that: evaluation must not gain the power to
   promote.
3. **Promote** -> an explicit, gated command. It verifies the evaluation report
   names *this exact candidate hash*, was produced under the *frozen protocol*,
   and states that the candidate *beats the baseline*. The current production
   artifact is archived first, and the swap is a single atomic rename, so a crash
   can never leave a half-written model in production.
4. **Rollback** -> restores the most recent archived artifact, byte for byte.
5. **Journal** -> every transition is appended to ``journal.jsonl`` with time,
   action, market, hashes and the reason. A rollback decision can be audited
   instead of guessed.

WHAT PROMOTION SPECIFICALLY REFUSES
-----------------------------------
- A candidate with no evaluation report.
- A report for a different candidate (promoting A on B's score).
- A report produced under a different protocol digest (numbers from an
  incompatible evaluation).
- A report that does not say the candidate beats the baseline.
- A derived market (double chance), which must never have an artifact.

There is deliberately no "force" flag. If a candidate cannot pass the gate, the
correct outcome is that production stays as it was.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from ml.app.model_store import (
    DERIVED_MARKETS,
    TRAINED_MARKETS,
    ModelBundle,
    load_bundle,
    save_bundle,
)


class ReleaseError(RuntimeError):
    """Raised when a release transition is refused or impossible."""


# The protocol digest of the frozen evaluation the promotion gate trusts.
# Imported lazily to avoid a circular import: ml.app.evaluate_markets imports
# model_store and elo, and release must stay importable on its own.
def _protocol_digest() -> str:
    from ml.app.evaluate_markets import current_protocol, protocol_digest

    return protocol_digest(current_protocol())


# Public, evaluated on import, so a caller can read it and a test can assert on
# it. Promoting a report produced under any other digest is refused.
PROTOCOL_DIGEST = _protocol_digest()


def file_sha256(path: Path | str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


@dataclass
class ReleaseStore:
    candidates_dir: Path
    production_dir: Path
    archive_dir: Path
    journal_path: Path

    # -- paths ---------------------------------------------------------------

    @classmethod
    def from_root(cls, root: Path | str) -> "ReleaseStore":
        base = Path(root)
        return cls(
            candidates_dir=base / "candidates",
            production_dir=base,
            archive_dir=base / "archive",
            journal_path=base / "release_journal.jsonl",
        )

    def production_path(self, market: str) -> Path:
        return self.production_dir / f"model_{market}.joblib"

    def _check_market(self, market: str) -> None:
        if market in DERIVED_MARKETS:
            raise ReleaseError(
                f"{market!r} is a derived market and must never have an artifact; "
                "it is projected from its source market at inference time"
            )
        if market not in TRAINED_MARKETS:
            raise ReleaseError(f"unknown market {market!r}; trained markets: {TRAINED_MARKETS}")

    # -- step 1: candidates --------------------------------------------------

    def save_candidate(
        self, bundle: ModelBundle, *, market: str, metadata: dict | None = None
    ) -> Path:
        """Persist a trained bundle to the candidate store, never to production."""
        self._check_market(market)
        staging = self.candidates_dir / market / ".staging"
        staging.mkdir(parents=True, exist_ok=True)
        tmp_path = staging / "candidate.joblib"
        save_bundle(bundle, tmp_path)

        digest = file_sha256(tmp_path)
        final = self.candidates_dir / market / f"{digest}.joblib"
        os.replace(tmp_path, final)

        meta = {
            "market": market,
            "sha256": digest,
            "model_version": bundle.model_version,
            "classes": list(bundle.classes),
            "trained_at": str(bundle.trained_at),
            "saved_at": datetime.now(timezone.utc).isoformat(),
            **(metadata or {}),
        }
        final.with_suffix(".json").write_text(json.dumps(meta, indent=2) + "\n")
        return final

    def candidate_metadata(self, candidate: Path) -> dict:
        meta_path = Path(candidate).with_suffix(".json")
        if not meta_path.is_file():
            raise ReleaseError(f"candidate metadata missing for {candidate}")
        return json.loads(meta_path.read_text())

    # -- step 3: promotion ---------------------------------------------------

    def promote(self, candidate: Path | str, *, market: str, report: dict | None,
                reason: str = "") -> dict:
        """Move a candidate into production, but only with a passing report."""
        self._check_market(market)
        candidate = Path(candidate)

        if not candidate.is_file():
            raise ReleaseError(f"candidate artifact not found: {candidate}")
        if not report:
            raise ReleaseError(
                "refusing to promote: no evaluation report. A model cannot be released "
                "on training output alone."
            )

        candidate_hash = file_sha256(candidate)

        report_hash = str(report.get("candidate_sha256") or "")
        if report_hash != candidate_hash:
            raise ReleaseError(
                f"refusing to promote: the evaluation report scores candidate "
                f"{report_hash or '<none>'}, but this artifact is {candidate_hash}. "
                "Promoting a different artifact on another model's score is not allowed."
            )

        expected = PROTOCOL_DIGEST
        if report.get("protocol_digest") != expected:
            raise ReleaseError(
                f"refusing to promote: report protocol {report.get('protocol_digest')!r} "
                f"does not match the frozen protocol {expected!r}"
            )

        if report.get("market") != market:
            raise ReleaseError(
                f"refusing to promote: report is for market {report.get('market')!r}, "
                f"not {market!r}"
            )

        if not report.get("beats_baseline"):
            raise ReleaseError(
                "refusing to promote: the candidate does not beat the baseline on the "
                "validation partition. Production stays unchanged."
            )

        # Validate before swapping: a corrupt candidate must not reach production.
        load_bundle(candidate)

        production = self.production_path(market)
        archived = None
        if production.is_file():
            archived = self._archive(production, market)

        # Atomic swap: copy beside the target, then a single rename. A crash
        # before the replace leaves production exactly as it was.
        self.production_dir.mkdir(parents=True, exist_ok=True)
        staging = self.production_dir / f".{market}.incoming"
        shutil.copyfile(candidate, staging)
        os.replace(staging, production)

        return self._journal(
            action="promote",
            market=market,
            detail={
                "candidate": str(candidate),
                "candidate_sha256": candidate_hash,
                "previous_sha256": file_sha256(archived) if archived else None,
                "archived_to": str(archived) if archived else None,
                "model_version": report.get("model_version"),
                "reason": reason,
            },
        )

    # -- step 4: rollback ----------------------------------------------------

    def rollback(self, *, market: str, reason: str = "") -> dict:
        """Restore the most recent archived production artifact."""
        self._check_market(market)
        archives = sorted((self.archive_dir / market).glob("*.joblib"))

        if not archives:
            raise ReleaseError(
                f"nothing to roll back for {market!r}: no previous artifact archived"
            )

        previous = archives[-1]
        load_bundle(previous)  # refuse to restore a corrupt archive

        production = self.production_path(market)
        staging = self.production_dir / f".{market}.rollback"
        self.production_dir.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(previous, staging)
        os.replace(staging, production)

        restored = file_sha256(production)
        # The archive is consumed: a second rollback would otherwise restore the
        # same file again and silently do nothing.
        previous.unlink()

        return self._journal(
            action="rollback",
            market=market,
            detail={
                "restored_from": str(previous),
                "restored_sha256": restored,
                "reason": reason,
            },
        )

    # -- helpers -------------------------------------------------------------

    def _archive(self, production: Path, market: str) -> Path:
        target_dir = self.archive_dir / market
        target_dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        target = target_dir / f"{stamp}_{file_sha256(production)[:12]}.joblib"
        shutil.copyfile(production, target)
        return target

    def _journal(self, *, action: str, market: str, detail: dict) -> dict:
        entry = {
            "at": datetime.now(timezone.utc).isoformat(),
            "action": action,
            "market": market,
            **detail,
        }
        self.journal_path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.journal_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry) + "\n")
        return entry

    def status(self) -> dict:
        """Current production hashes and the last few journal entries."""
        entries = []
        if self.journal_path.is_file():
            entries = [json.loads(line) for line in self.journal_path.read_text().splitlines()]

        production = {}
        for market in TRAINED_MARKETS:
            path = self.production_path(market)
            production[market] = file_sha256(path) if path.is_file() else None

        return {
            "production": production,
            "archived": {
                market: len(list((self.archive_dir / market).glob("*.joblib")))
                for market in TRAINED_MARKETS
            },
            "recent": entries[-5:],
        }
