"""Operator CLI for the model release workflow.

    # where production stands right now
    python -m ml.app.release_cli status

    # list candidates for a market, newest first
    python -m ml.app.release_cli candidates --market 1x2

    # promote a candidate, using an evaluation report as the gate
    python -m ml.app.release_cli promote \
        --market 1x2 \
        --candidate /app/artifacts/candidates/1x2/<sha>.joblib \
        --report /app/artifacts/evaluation/release_report_1x2.json \
        --reason "beats baseline on validation, paired CI excludes zero"

    # undo the last promotion
    python -m ml.app.release_cli rollback --market 1x2 --reason "calibration drift"

Nothing here runs automatically. Daily data synchronization does not import this
module (a test enforces that), so an import can never deploy a model.

Exit codes: 0 success, 1 refused (gate failed), 2 usage or missing file.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from ml.app.release import PROTOCOL_DIGEST, ReleaseError, ReleaseStore


def _default_root() -> Path:
    return Path(os.environ.get("ML_ARTIFACTS_DIR", "/app/artifacts"))


def build_report_from_evaluation(market: str, evaluation_payload: dict,
                                 candidate_sha256: str, baseline: str = "frequency") -> dict:
    """Turn an evaluation payload into the report the promotion gate reads.

    The gate needs four facts that the evaluation already produces, restated in
    one place so a reader can see exactly what is being asserted:

    - which candidate is being scored (its content hash),
    - which protocol scored it,
    - which model won on VALIDATION,
    - whether that winner beat the baseline on validation, with the paired CI.
    """
    models = {m["name"]: m for m in evaluation_payload.get("models", [])}
    selected = evaluation_payload.get("selected_by_validation_log_loss")
    if selected not in models:
        raise ReleaseError(f"selected model {selected!r} is not in the evaluation report")

    selected_validation = models[selected]["metrics"]["validation"]
    baseline_validation = models[baseline]["metrics"]["validation"]

    delta = selected_validation.get("log_loss_delta_vs_baseline", {})
    # "Beats the baseline" requires the paired interval to exclude zero in the
    # favourable direction. A point estimate that is merely lower is not enough:
    # that is how a difference smaller than the sampling noise gets promoted.
    beats = bool(delta) and delta.get("ci_high") is not None and delta["ci_high"] < 0

    return {
        "market": market,
        "protocol_digest": evaluation_payload.get("protocol_digest"),
        "candidate_sha256": candidate_sha256,
        "selected_by_validation_log_loss": selected,
        "validation_log_loss_of_selected": selected_validation.get("log_loss"),
        "baseline_validation_log_loss": baseline_validation.get("log_loss"),
        "validation_delta_vs_baseline": delta,
        "beats_baseline": beats,
        "holdout_status": evaluation_payload.get("test_partition_status", "unknown"),
        "model_version": evaluation_payload.get("model_version"),
        "note": (
            "Selection is by validation log loss only. Beats-baseline requires the "
            "paired bootstrap CI of the validation log-loss delta to lie entirely "
            "below zero."
        ),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Model release workflow")
    parser.add_argument("--artifacts-dir", default=None,
                        help="artifact root (default: $ML_ARTIFACTS_DIR or /app/artifacts)")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("status", help="production hashes, archives and recent journal")

    cand = sub.add_parser("candidates", help="list candidates for a market")
    cand.add_argument("--market", required=True)

    promo = sub.add_parser("promote", help="promote a candidate that passed its evaluation")
    promo.add_argument("--market", required=True)
    promo.add_argument("--candidate", required=True)
    promo.add_argument("--report", required=True, help="evaluation report JSON")
    promo.add_argument("--reason", default="")

    roll = sub.add_parser("rollback", help="restore the previous production artifact")
    roll.add_argument("--market", required=True)
    roll.add_argument("--reason", default="")

    report = sub.add_parser(
        "report", help="build a gate report from an evaluation payload"
    )
    report.add_argument("--market", required=True)
    report.add_argument("--evaluation", required=True)
    report.add_argument("--candidate", required=True)
    report.add_argument("--out", required=True)

    print_digest = sub.add_parser("protocol-digest", help="print the frozen protocol digest")

    args = parser.parse_args(argv)
    store = ReleaseStore.from_root(args.artifacts_dir or _default_root())

    try:
        if args.command == "status":
            print(json.dumps(store.status(), indent=2))

        elif args.command == "candidates":
            files = sorted(
                (store.candidates_dir / args.market).glob("*.joblib"),
                key=lambda p: p.stat().st_mtime,
                reverse=True,
            )
            if not files:
                print(f"no candidates for {args.market}")
            for path in files:
                meta = json.loads(path.with_suffix(".json").read_text())
                print(f"{path.name}  version={meta.get('model_version')} "
                      f"trained_at={meta.get('trained_at')}")

        elif args.command == "promote":
            report_path = Path(args.report)
            if not report_path.is_file():
                print(f"evaluation report not found: {report_path}", file=sys.stderr)
                return 2
            record = store.promote(
                args.candidate,
                market=args.market,
                report=json.loads(report_path.read_text()),
                reason=args.reason,
            )
            print(json.dumps(record, indent=2))

        elif args.command == "rollback":
            print(json.dumps(store.rollback(market=args.market, reason=args.reason), indent=2))

        elif args.command == "report":
            from ml.app.release import file_sha256

            payload = json.loads(Path(args.evaluation).read_text())
            built = build_report_from_evaluation(
                args.market, payload, file_sha256(args.candidate)
            )
            Path(args.out).write_text(json.dumps(built, indent=2) + "\n")
            print(f"wrote {args.out}; beats_baseline={built['beats_baseline']}")

        elif args.command == "protocol-digest":
            print(PROTOCOL_DIGEST)

    except ReleaseError as exc:
        print(f"refused: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
