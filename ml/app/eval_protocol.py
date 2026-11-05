"""Evaluation protocol and observation-partition integrity.

THE PROBLEM THIS SOLVES
-----------------------
The project's test window has already been scored: model selection, Elo and the
metric reporting were all revised after it was first evaluated. Any script that
re-scores those rows and prints "final test log loss" is producing exploratory
evidence dressed up as out-of-sample proof.

A manifest of *spent* observations cannot fully undo that, but it can stop the
machine from repeating the mistake: the evaluator asks this module whether a row is
still clean before it will treat it as holdout evidence.

THREE THINGS, KEPT SEPARATE
---------------------------
1. `Protocol`  — the authoritative boundaries. Versioned, hashed, serialisable.
2. `SpentManifest` — which observations have already been used, and for what.
3. `require_clean_holdout` — the gate that refuses contaminated evaluation.

A row is only "holdout" if it is BOTH after the validation cut AND never used for
training, selection, calibration or a previous evaluation. Either condition alone is
not enough, which is exactly the mistake the old harness made.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

# --------------------------------------------------------------------------- vocabulary

# What an observation has been used for. Stored as strings so manifests stay readable
# and remain valid when this module changes.
TRAINING = "training"
MODEL_SELECTION = "model_selection"
CALIBRATION_FIT = "calibration_fit"
CALIBRATION_ASSESSMENT = "calibration_assessment"
EVALUATION = "evaluation"
HOLDOUT = "holdout"

# Partitions an observation can belong to, by date.
PARTITIONS = (TRAINING, MODEL_SELECTION, HOLDOUT)


class ProtocolError(ValueError):
    """The protocol itself is malformed (bad dates, impossible boundaries)."""


class PartitionError(RuntimeError):
    """A request would treat non-holdout observations as holdout evidence."""


# --------------------------------------------------------------------------- helpers


def _parse_date(value: Any, field_name: str) -> date:
    """Parse an ISO date, refusing anything ambiguous.

    Only `YYYY-MM-DD` is accepted. Slashed forms are locale-dependent (US month-first
    vs European day-first) and a silent misparse here would move a boundary by
    months, so it is rejected rather than guessed.
    """
    if isinstance(value, date):
        return value
    if not isinstance(value, str) or not value:
        raise ProtocolError(f"{field_name} must be an ISO date string, got {value!r}")

    try:
        return date.fromisoformat(value)
    except ValueError as exc:  # pragma: no cover - message is the assertion
        raise ProtocolError(
            f"{field_name} must be YYYY-MM-DD, got {value!r} ({exc})"
        ) from exc


# --------------------------------------------------------------------------- protocol


@dataclass(frozen=True)
class Protocol:
    """Authoritative evaluation boundaries.

    `train_end` is the last day INCLUDED in training. `validation_end` is the last
    day included in model selection. Everything after `validation_end` is holdout,
    subject to the manifest also showing it is clean.
    """

    version: str
    train_end: Any
    validation_end: Any
    feature_version: str
    seeds: Mapping[str, int] = field(default_factory=dict)
    class_orders: Mapping[str, Sequence[str]] = field(default_factory=dict)
    notes: str = ""

    def __post_init__(self) -> None:
        train_end = _parse_date(self.train_end, "train_end")
        validation_end = _parse_date(self.validation_end, "validation_end")

        if validation_end < train_end:
            raise ProtocolError(
                f"validation_end ({validation_end}) precedes train_end ({train_end}); "
                "the partitions would overlap"
            )
        if not self.feature_version:
            raise ProtocolError("feature_version is required")

        # Normalise to date objects so callers cannot compare a string to a date.
        object.__setattr__(self, "train_end", train_end)
        object.__setattr__(self, "validation_end", validation_end)

    def to_dict(self) -> dict[str, Any]:
        return {
            "version": self.version,
            "train_end": self.train_end.isoformat(),
            "validation_end": self.validation_end.isoformat(),
            "feature_version": self.feature_version,
            "seeds": dict(self.seeds),
            "class_orders": {k: list(v) for k, v in self.class_orders.items()},
            "notes": self.notes,
        }

    def digest(self) -> str:
        """Stable hash of the boundaries.

        Deliberately excludes `notes`: prose must not change a result's identity,
        but every number that affects a split must.
        """
        material = {
            "version": self.version,
            "train_end": self.train_end.isoformat(),
            "validation_end": self.validation_end.isoformat(),
            "feature_version": self.feature_version,
            "seeds": dict(sorted(self.seeds.items())),
            "class_orders": {k: list(v) for k, v in sorted(self.class_orders.items())},
        }
        payload = json.dumps(material, sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(payload.encode()).hexdigest()

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "Protocol":
        return cls(
            version=payload["version"],
            train_end=payload["train_end"],
            validation_end=payload["validation_end"],
            feature_version=payload["feature_version"],
            seeds=payload.get("seeds", {}),
            class_orders=payload.get("class_orders", {}),
            notes=payload.get("notes", ""),
        )


def partition_for_row(kickoff_at: Any, protocol: Protocol) -> str:
    """Which chronological partition a row belongs to.

    Inclusive at both cuts: a match ON `train_end` was available to training.
    """
    day = _parse_date(kickoff_at, "kickoff_at")

    if day <= protocol.train_end:
        return TRAINING
    if day <= protocol.validation_end:
        return MODEL_SELECTION
    return HOLDOUT


# --------------------------------------------------------------------------- manifest


@dataclass
class SpentManifest:
    """Which observations have already influenced model development or evaluation.

    `entries` are dicts with at least `match_id` and `used_for` (a list of the
    vocabulary constants above). `kickoff_at` is optional but recommended, because it
    lets the gate apply the chronological rule without a second data source.
    """

    entries: list[dict[str, Any]] = field(default_factory=list)
    generated_at: str = ""
    protocol_version: str = ""
    source: str = ""

    def _by_id(self) -> dict[int, dict[str, Any]]:
        index: dict[int, dict[str, Any]] = {}
        for entry in self.entries:
            index[int(entry["match_id"])] = entry
        return index

    def is_spent(self, match_id: int) -> bool:
        """True when the row has been used for anything at all."""
        entry = self._by_id().get(int(match_id))
        return bool(entry and entry.get("used_for"))

    def used_for(self, match_id: int) -> list[str]:
        entry = self._by_id().get(int(match_id))
        return list(entry.get("used_for", [])) if entry else []

    def kickoff_of(self, match_id: int) -> str | None:
        entry = self._by_id().get(int(match_id))
        return entry.get("kickoff_at") if entry else None

    def assert_calibration_disjoint(self) -> None:
        """A calibrator must not be assessed on the rows it was fitted on."""
        offenders = [
            entry["match_id"]
            for entry in self.entries
            if CALIBRATION_FIT in entry.get("used_for", [])
            and CALIBRATION_ASSESSMENT in entry.get("used_for", [])
        ]
        if offenders:
            raise PartitionError(
                "calibration_fit and calibration_assessment share observations "
                f"(match ids: {', '.join(str(m) for m in sorted(offenders))}). "
                "A calibrator cannot be assessed on the data it was fitted on."
            )

    def to_dict(self) -> dict[str, Any]:
        return {
            "generated_at": self.generated_at,
            "protocol_version": self.protocol_version,
            "source": self.source,
            "entries": self.entries,
        }

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), indent=2, sort_keys=True)

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "SpentManifest":
        return cls(
            entries=list(payload.get("entries", [])),
            generated_at=payload.get("generated_at", ""),
            protocol_version=payload.get("protocol_version", ""),
            source=payload.get("source", ""),
        )

    @classmethod
    def from_json(cls, payload: str) -> "SpentManifest":
        return cls.from_dict(json.loads(payload))

    @classmethod
    def load(cls, path: str | Path) -> "SpentManifest":
        """Load from disk.

        A missing file raises rather than yielding an empty manifest. "I could not
        find the record of what is spent" and "nothing is spent" must never be the
        same answer — the second one would silently enable the exact evaluation this
        module exists to prevent.
        """
        path = Path(path)
        if not path.exists():
            raise PartitionError(
                f"spent-manifest not found at {path}. Refusing to assume nothing is "
                "spent; regenerate the manifest before evaluating."
            )
        return cls.from_json(path.read_text())


# --------------------------------------------------------------------------- the gate


@dataclass(frozen=True)
class HoldoutDecision:
    allowed: bool
    match_ids: list[int]
    protocol_digest: str


def _row_identifier(row: Any) -> int:
    if isinstance(row, Mapping):
        return int(row["match_id"])
    return int(row)


def _row_kickoff(row: Any, manifest: SpentManifest) -> Any:
    if isinstance(row, Mapping) and row.get("kickoff_at"):
        return row["kickoff_at"]
    return manifest.kickoff_of(_row_identifier(row))


def require_clean_holdout(
    rows: Iterable[Any],
    *,
    protocol: Protocol,
    manifest: SpentManifest,
) -> HoldoutDecision:
    """Refuse to treat rows as holdout evidence unless they are genuinely clean.

    A row must satisfy BOTH:
      1. it falls after `protocol.validation_end` (chronological holdout), and
      2. the manifest does not record it as used for anything.

    Failing either raises, and the error names every offending row so the caller can
    see the full extent rather than fixing them one at a time.
    """
    ids: list[int] = []
    spent: list[int] = []
    too_early: list[int] = []

    for row in rows:
        match_id = _row_identifier(row)
        ids.append(match_id)

        if manifest.is_spent(match_id):
            spent.append(match_id)
            continue

        kickoff = _row_kickoff(row, manifest)
        if kickoff is not None and partition_for_row(kickoff, protocol) != HOLDOUT:
            too_early.append(match_id)

    problems: list[str] = []
    if spent:
        problems.append(
            f"{len(spent)} row(s) already used (match ids: "
            f"{', '.join(str(m) for m in sorted(spent)[:10])}): these would make the "
            "result exploratory, not an untouched holdout"
        )
    if too_early:
        problems.append(
            f"{len(too_early)} row(s) fall on or before validation_end "
            f"({protocol.validation_end.isoformat()}); they are not holdout evidence "
            f"regardless of whether they were scored before "
            f"(match ids: {', '.join(str(m) for m in sorted(too_early)[:10])})"
        )

    if problems:
        raise PartitionError(
            "refusing to evaluate as holdout: " + "; ".join(problems)
        )

    return HoldoutDecision(allowed=True, match_ids=ids, protocol_digest=protocol.digest())
