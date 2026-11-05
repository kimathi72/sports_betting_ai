"""Immutable record of a published model generation.

WHAT A FREEZE IS FOR
--------------------
Given a prediction, another engineer must be able to answer: which artifact, which
feature version, which training data, which hyperparameters, and which evaluation
protocol produced it? A filename is not enough — artifacts get overwritten.

This module writes a single JSON document that records that, including a SHA-256 of
every artifact so a later change is detectable. It never modifies an artifact and
never promotes anything.

DELIBERATE LIMITS
-----------------
* It reads metadata that already exists (`*.meta.json`, `published_models.json`);
  it does not infer anything the artifacts do not state.
* A missing field is recorded as null rather than guessed.
"""

from __future__ import annotations

import hashlib
import json
import platform
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping

FREEZE_SCHEMA_VERSION = 1

# Libraries whose version can change a prediction. Recorded when importable; an
# absent library is recorded as null, never omitted, so the gap is visible.
_TRACKED_LIBRARIES = ("numpy", "scipy", "scikit-learn", "joblib", "pydantic", "fastapi")


def sha256_of(path: str | Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _library_versions() -> dict[str, str | None]:
    versions: dict[str, str | None] = {}
    for name in _TRACKED_LIBRARIES:
        try:
            module = __import__(name)
            versions[name] = getattr(module, "__version__", None)
        except Exception:  # pragma: no cover - environment-dependent
            versions[name] = None
    return versions


@dataclass
class ModelFreeze:
    """A frozen generation. Serialised as `freeze.json` next to the artifacts."""

    frozen_at: str
    protocol_version: str
    protocol_digest: str
    published_models: dict[str, Any]
    artifacts: dict[str, dict[str, Any]]
    runtime: dict[str, Any] = field(default_factory=dict)
    notes: str = ""
    schema_version: int = FREEZE_SCHEMA_VERSION

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "frozen_at": self.frozen_at,
            "protocol_version": self.protocol_version,
            "protocol_digest": self.protocol_digest,
            "published_models": self.published_models,
            "artifacts": self.artifacts,
            "runtime": self.runtime,
            "notes": self.notes,
        }

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), indent=2, sort_keys=True)

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "ModelFreeze":
        return cls(
            frozen_at=payload["frozen_at"],
            protocol_version=payload["protocol_version"],
            protocol_digest=payload["protocol_digest"],
            published_models=payload.get("published_models", {}),
            artifacts=payload.get("artifacts", {}),
            runtime=payload.get("runtime", {}),
            notes=payload.get("notes", ""),
            schema_version=payload.get("schema_version", FREEZE_SCHEMA_VERSION),
        )

    def describe(self) -> str:
        lines = [
            f"frozen_at         : {self.frozen_at}",
            f"protocol          : {self.protocol_version} ({self.protocol_digest[:12]}…)",
            f"artifacts frozen  : {len(self.artifacts)}",
        ]
        for name, artifact in sorted(self.artifacts.items()):
            lines.append(
                f"  {name:<24} sha256={artifact['sha256'][:12]}… "
                f"feature={artifact.get('feature_version')} "
                f"train={artifact.get('train_range')}"
            )
        return "\n".join(lines)


def _meta_for(artifact_path: Path) -> dict[str, Any]:
    """Read the sibling `*.meta.json` if present. Missing is null, not inferred."""
    candidates = [
        artifact_path.with_suffix(artifact_path.suffix + ".meta.json"),
        artifact_path.with_suffix(".meta.json"),
    ]
    for candidate in candidates:
        if candidate.exists():
            try:
                return json.loads(candidate.read_text())
            except json.JSONDecodeError:
                return {"_error": f"unreadable metadata: {candidate.name}"}
    return {}


def build_freeze(
    artifacts_dir: str | Path,
    *,
    protocol_version: str,
    protocol_digest: str,
    frozen_at: str | None = None,
    notes: str = "",
) -> ModelFreeze:
    """Describe every artifact in `artifacts_dir` without touching any of them."""
    artifacts_dir = Path(artifacts_dir)
    published_path = artifacts_dir / "published_models.json"

    if published_path.exists():
        published = json.loads(published_path.read_text())
    else:
        published = {}

    artifacts: dict[str, dict[str, Any]] = {}
    for path in sorted(artifacts_dir.iterdir()):
        if path.suffix not in {".joblib", ".pkl"} or not path.is_file():
            continue

        meta = _meta_for(path)
        trained_on = meta.get("trained_on") or {}

        # The metadata uses `from`/`to`, not `start`/`end`. Both spellings are read so
        # this survives whichever the training script writes; an earlier version only
        # accepted start/end and silently recorded null for every artifact, which
        # defeats the point of the freeze.
        train_start = trained_on.get("from") or trained_on.get("start")
        train_end = trained_on.get("to") or trained_on.get("end")
        train_range = [train_start, train_end] if (train_start or train_end) else None

        artifacts[path.name] = {
            "sha256": sha256_of(path),
            "bytes": path.stat().st_size,
            "algorithm": meta.get("algorithm"),
            "feature_version": meta.get("feature_version"),
            "n_features": len(meta.get("feature_names", [])) or None,
            "classes": meta.get("classes"),
            "market": meta.get("market"),
            "model_version": meta.get("model_version"),
            "train_range": train_range,
            "rows": trained_on.get("rows"),
            "trained_at": meta.get("trained_at"),
            "split": meta.get("split"),
            "selection": meta.get("selection") or meta.get("chosen_by_validation"),
            "hyperparameters": meta.get("hyperparameters") or meta.get("params"),
            "rho": meta.get("rho"),
        }

    return ModelFreeze(
        frozen_at=frozen_at or datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        protocol_version=protocol_version,
        protocol_digest=protocol_digest,
        published_models=published,
        artifacts=artifacts,
        runtime={
            "python": sys.version.split()[0],
            "platform": platform.platform(),
            "libraries": _library_versions(),
        },
        notes=notes,
    )


def verify_freeze(freeze: ModelFreeze, artifacts_dir: str | Path) -> list[str]:
    """Return a list of discrepancies between the freeze and the files on disk.

    Empty list means every artifact is byte-identical to what was frozen. This is
    what makes the record meaningful: a freeze nobody checks is a comment.
    """
    artifacts_dir = Path(artifacts_dir)
    problems: list[str] = []

    for name, recorded in freeze.artifacts.items():
        path = artifacts_dir / name
        if not path.exists():
            problems.append(f"{name}: recorded in freeze but missing on disk")
            continue
        actual = sha256_of(path)
        if actual != recorded["sha256"]:
            problems.append(
                f"{name}: checksum changed (frozen {recorded['sha256'][:12]}…, "
                f"now {actual[:12]}…)"
            )

    return problems
