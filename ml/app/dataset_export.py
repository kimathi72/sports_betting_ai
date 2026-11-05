"""Exports the canonical match dataset from PostgreSQL as JSON lines.

Rails owns the schema; the ML service must not re-implement its joins. This script
performs exactly one read-only query and writes one JSON object per completed or
scheduled match, in chronological order, with the columns the feature builder needs
and nothing else (no scores of future matches are hidden here because the feature
builder itself refuses to read them — but the export stays minimal anyway).

Usage (inside the ml container, where psycopg2 is installed)::

    docker compose run --rm --entrypoint python \\
      -e DATABASE_URL=postgresql://sports_ai:local_dev_only@postgres:5432/sports_betting_ai_development \\
      ml -m ml.app.dataset_export --out /app/artifacts/evaluation/matches.jsonl

The output is deterministic for a given database state: rows are ordered by
(kickoff_at, id) and keys are written in sorted order.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

try:  # pragma: no cover
    import psycopg2
    from psycopg2.extras import RealDictCursor
except ImportError:  # pragma: no cover
    psycopg2 = None  # type: ignore[assignment]
    RealDictCursor = None  # type: ignore[assignment]

from ml.app.dataset_quality import DEFAULT_DSN

QUERY = """
SELECT m.id,
       m.competition_id,
       m.season_id,
       s.name  AS season,
       c.name  AS competition,
       c.country,
       m.home_team_id,
       m.away_team_id,
       h.name  AS home_team,
       a.name  AS away_team,
       m.kickoff_at,
       m.status,
       m.home_score,
       m.away_score
FROM matches m
JOIN seasons s ON s.id = m.season_id
JOIN competitions c ON c.id = s.competition_id
JOIN teams h ON h.id = m.home_team_id
JOIN teams a ON a.id = m.away_team_id
WHERE m.kickoff_at IS NOT NULL
ORDER BY m.kickoff_at, m.id
"""


def _encode(value: Any) -> Any:
    if hasattr(value, "isoformat"):
        # ISO-8601 with an explicit offset; the feature builder normalises to UTC.
        return value.isoformat()
    return value


def fetch_rows(dsn: str) -> list[dict[str, Any]]:
    if psycopg2 is None:  # pragma: no cover
        raise RuntimeError("psycopg2 is required to export the dataset")
    connection = psycopg2.connect(dsn)
    try:
        with connection.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(QUERY)
            return [{k: _encode(v) for k, v in row.items()} for row in cur.fetchall()]
    finally:
        connection.close()


def write_jsonl(rows: list[dict[str, Any]], path: str) -> int:
    with open(path, "w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")
    return len(rows)


def read_jsonl(path: str) -> list[dict[str, Any]]:
    with open(path, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, help="destination .jsonl path")
    parser.add_argument("--dsn", default=None)
    args = parser.parse_args(argv)

    rows = fetch_rows(args.dsn or os.environ.get("DATABASE_URL") or DEFAULT_DSN)
    count = write_jsonl(rows, args.out)
    completed = sum(1 for r in rows if r["status"] == "completed")
    competitions = len({r["competition"] for r in rows})
    print(
        f"exported {count} matches ({completed} completed) across {competitions} "
        f"competitions -> {args.out}"
    )
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
