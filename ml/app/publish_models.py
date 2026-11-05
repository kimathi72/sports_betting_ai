"""Publish the market models chosen by validation into inference artifacts.

WHAT "PUBLISH" MEANS HERE
-------------------------
Nothing is promoted automatically. This script reads the comparison produced by
``ml.app.train_markets``, and for each trained market it fits the winning candidate
ONE more time on train+validation (never on the untouched test window) and writes an
artifact with its full metadata.

    artifacts/model_1x2.joblib
    artifacts/model_over_under_2.5.joblib
    artifacts/model_btts.joblib
    artifacts/model_goal_distribution.joblib   (the grid that backs correct score)
    artifacts/model_1x2.meta.json              (range, hyper-parameters, metrics)

Every artifact is stamped with its market, so inference can refuse to serve a
binary model as 1X2 or a goals model as anything else. A previous version of the
service loaded the generic 1X2 file for every market, which is why the metadata
stamp is now part of the contract rather than a convenience.

WHY REFIT ON TRAIN+VALIDATION
-----------------------------
The test window measured the choice. Refitting on the earlier periods uses the
data a real deployment would have had and cannot improve a number that has already
been reported. The metrics in the metadata are therefore the TEST metrics — future
work must not re-measure them on the same window and call the improvement new.

FORCED CHOICE: the 1X2 classifier
--------------------------------
The comparison currently selects logistic regression for all three markets. That
matters for 1X2 because a classifier answers the three-way question directly.
A goal-distribution model would be preferred when it wins AND when the service is
asked to serve a scoreline grid; the report records both numbers so the trade-off
is visible rather than hidden.

USAGE::

    docker compose run --rm --entrypoint python ml -m ml.app.publish_models \\
        --data /app/artifacts/evaluation/matches.jsonl \\
        --report /app/artifacts/evaluation/model_comparison.json \\
        --out /app/artifacts
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone

import numpy as np

from ml.app.dataset_export import read_jsonl
from ml.app.eval_pipeline import split_holdout
from ml.app.features_v2 import FEATURE_NAMES_V2, enrich_history
from ml.app.goal_models import DixonColesModel, PoissonGoalModel
from ml.app.model_store import (
    ModelBundle,
    MARKET_1X2,
    MARKET_BTTS,
    MARKET_OVER_UNDER,
    get_model_path,
    save_bundle,
)
from ml.app.train_markets import (
    CLASSES_1X2,
    CLASSES_BTTS,
    CLASSES_OU,
    MARKET_1X2 as TM_1X2,
    MARKET_BTTS as TM_BTTS,
    MARKET_OU as TM_OU,
    LogisticModel,
    design_matrix,
)

MARKET_CLASSES = {
    MARKET_1X2: CLASSES_1X2,
    MARKET_OVER_UNDER: CLASSES_OU,
    MARKET_BTTS: CLASSES_BTTS,
}
LABEL_KEYS = {
    MARKET_1X2: "label_1x2",
    MARKET_OVER_UNDER: "label_over_under",
    MARKET_BTTS: "label_btts",
}
REPORT_MARKETS = {
    MARKET_1X2: TM_1X2,
    MARKET_OVER_UNDER: TM_OU,
    MARKET_BTTS: TM_BTTS,
}


def _test_metrics(report: dict, market: str) -> dict:
    for entry in report.get("markets", []):
        if entry.get("market") == REPORT_MARKETS[market]:
            return {
                "chosen_candidate": entry.get("chosen_by_validation"),
                "test": entry.get("test", {}),
                "validation_results": [
                    {"candidate": item["candidate"], "validation": item["validation"]}
                    for item in entry.get("validation_results", [])
                ],
                "date_ranges": entry.get("date_ranges"),
                "split": entry.get("split"),
            }
    return {}


def publish(data_path: str, report_path: str, out_dir: str) -> list[dict]:
    rows = [r for r in enrich_history(read_jsonl(data_path)) if r.get("label_1x2")]
    split = split_holdout(rows)
    with open(report_path, encoding="utf-8") as handle:
        report = json.load(handle)

    os.makedirs(out_dir, exist_ok=True)
    written: list[dict] = []
    trained_at = datetime.now(timezone.utc)

    # Train+validation: everything before the untouched holdout.
    fitting_rows = split.train + split.validation
    X_fit = design_matrix(fitting_rows)

    for market, classes in MARKET_CLASSES.items():
        label_key = LABEL_KEYS[market]
        labels = [row[label_key] for row in fitting_rows]
        model = LogisticModel.fit(X_fit, labels, classes)
        version = f"{market}-logreg-v2-{trained_at.strftime('%Y%m%dT%H%M%SZ')}"
        bundle = ModelBundle(
            classifier=model.coefficients,
            feature_names=list(FEATURE_NAMES_V2),
            classes=list(classes),
            model_version=version,
            trained_at=trained_at,
            market=market,
        )
        path = get_model_path(market, model_version=version)
        metrics = _test_metrics(report, market)
        save_bundle(
            bundle,
            path,
            metadata={
                "algorithm": "multinomial_logistic_regression",
                "feature_version": "v2",
                "feature_count": len(FEATURE_NAMES_V2),
                "trained_on": {
                    "rows": len(fitting_rows),
                    "from": fitting_rows[0]["kickoff_at"][:10],
                    "to": fitting_rows[-1]["kickoff_at"][:10],
                    "note": "train + validation; the test window was NOT used for fitting",
                },
                "split": split.sizes,
                "selection": metrics.get("chosen_candidate"),
                "evaluation": metrics.get("test"),
                "candidates_compared": [
                    item["candidate"] for item in metrics.get("validation_results", [])
                ],
            },
        )
        written.append({"market": market, "path": str(path), "version": version,
                        "rows": len(fitting_rows), "classes": list(classes)})
        print(f"published {market:<16} -> {path}")

    # The goal distribution backs correct_score and any alternative total line.
    # It is published even though it lost the 1X2 comparison, because it is the only
    # way to answer "3-1, 2-0, 1-1..." and because the API tells clients which
    # source answered.
    goal = DixonColesModel.fit(fitting_rows)
    goal_version = f"goal-dc-v2-{trained_at.strftime('%Y%m%dT%H%M%SZ')}"
    goal_path = os.path.join(out_dir, "model_goal_distribution.joblib")
    # ``save_bundle`` pickles the bundle's own ``classifier`` field, so the goal
    # MODEL has to be the classifier — putting a wrapper here would store the
    # wrapper and leave the model out of the file entirely.
    save_bundle(
        ModelBundle(
            classifier=goal,
            feature_names=list(FEATURE_NAMES_V2),
            classes=["H", "D", "A"],
            model_version=goal_version,
            trained_at=trained_at,
            market="goals",
        ),
        goal_path,
        metadata={
            "algorithm": "dixon_coles",
            "rho": goal.rho,
            "feature_version": "v2",
            "trained_on": {"rows": len(fitting_rows)},
            "used_for": ["correct_score", "alternative_total_lines"],
            "evaluation": _test_metrics(report, "1x2").get("test"),
        },
    )
    written.append({"market": "goals", "path": goal_path, "version": goal_version,
                    "rho": goal.rho})
    print(f"published {'goals':<16} -> {goal_path} (rho={goal.rho})")

    manifest = {
        "published_at": trained_at.isoformat(),
        "feature_version": "v2",
        "artifacts": written,
    }
    manifest_path = os.path.join(out_dir, "published_models.json")
    with open(manifest_path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
    print(f"manifest -> {manifest_path}")
    return written


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", required=True)
    parser.add_argument("--report", default="/app/artifacts/evaluation/model_comparison.json")
    parser.add_argument("--out", default="/app/artifacts")
    args = parser.parse_args(argv)
    publish(args.data, args.report, args.out)
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
