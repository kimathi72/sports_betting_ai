"""Generate the model freeze for the published generation (read-only).

Writes one JSON document under ml/evaluation/. It does NOT touch any artifact.
Run with the ML container image, repo mounted read-only:

    python ml/scripts/freeze_current_generation.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ML_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ML_ROOT))

from app.eval_protocol import Protocol  # noqa: E402
from app.model_freeze import build_freeze, verify_freeze  # noqa: E402

PROTOCOL_PATH = ML_ROOT / "evaluation" / "eval_protocol_v2.json"
ARTIFACTS_DIR = ML_ROOT / "artifacts"
OUTPUT_PATH = ML_ROOT / "evaluation" / "model_freeze_v2.1.json"


def main() -> int:
    protocol = Protocol.from_dict(json.loads(PROTOCOL_PATH.read_text()))

    freeze = build_freeze(
        ARTIFACTS_DIR,
        protocol_version=protocol.version,
        protocol_digest=protocol.digest(),
        notes=(
            "Frozen published generation. Produced read-only: no artifact was "
            "modified. Verify with app.model_freeze.verify_freeze before relying on "
            "any metric attached to this generation."
        ),
    )

    OUTPUT_PATH.write_text(freeze.to_json())

    print(freeze.describe())
    print()
    problems = verify_freeze(freeze, ARTIFACTS_DIR)
    print(f"verification: {'OK - all artifacts match' if not problems else problems}")
    print(f"written: {OUTPUT_PATH.relative_to(ML_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
