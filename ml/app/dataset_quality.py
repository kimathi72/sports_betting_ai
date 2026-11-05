"""Reproducible dataset-quality report over the canonical database.

WHY THIS IS A SCRIPT AND NOT A MODEL MODULE
-------------------------------------------
Quality checks are read-only SQL over Rails' canonical tables. Putting them in the
ML service would give the service a database dependency it does not otherwise have
(it receives JSON, not rows), and would duplicate the schema knowledge Rails owns.

WHAT IT DOES NOT DO
-------------------
It reports. It never deletes, repairs or "fixes" a row. A questionable fixture is
listed with its id so a human can decide; silently correcting data is how a
training set stops being auditable.

USAGE (from the repository root, inside the ML container so psycopg2 is present)::

    docker compose run --rm --entrypoint python \\
      -e DATABASE_URL=postgresql://sports_ai:local_dev_only@postgres:5432/sports_betting_ai_development \\
      ml -m ml.app.dataset_quality --json ml/artifacts/evaluation/dataset_quality.json

The JSON is deterministic: same database state -> byte-identical report (rows are
sorted, sets are sorted, no timestamps are embedded in the checks themselves).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter
from typing import Any

try:  # pragma: no cover - exercised only when psycopg2 is unavailable
    import psycopg2
    from psycopg2.extras import RealDictCursor
except ImportError:  # pragma: no cover
    psycopg2 = None  # type: ignore[assignment]
    RealDictCursor = None  # type: ignore[assignment]


DEFAULT_DSN = (
    "postgresql://sports_ai:local_dev_only@postgres:5432/sports_betting_ai_development"
)

# A kickoff outside these years is either a parsing bug or a placeholder date.
PLAUSIBLE_KICKOFF_YEARS = (2000, 2100)

# A completed match more than this many days before the season's first kickoff
# would be a season-attribution error.
MAX_DAYS_BEFORE_SEASON_START = 60
MAX_DAYS_AFTER_SEASON_END = 60


# A complete league-season fixture count, used only to spot a truncated import.
# Competitions absent from this map are not judged incomplete. Several leagues
# change size between seasons (Ligue 1 and the Eredivisie 18 clubs = 306, Scottish
# Premiership 12 clubs = 228, Bundesliga 18 = 306), so the value is the minimum a
# COMPLETE season of that competition can have; a shorter season is reported.
FULL_SEASON_FIXTURES = {
    "Premier League": 380,
    "Championship": 552,
    "La Liga": 380,
    "Bundesliga": 306,
    "Serie A": 380,
    "Ligue 1": 306,
    "Eredivisie": 306,
    "Pro League": 240,
    "Primeira Liga": 306,
    "Super Lig": 380,
    "Scottish Premiership": 228,
}

# Seasons starting in this year or later are in progress and are expected to be
# shorter than a full campaign; they are never reported as truncated.
IN_PROGRESS_FROM = "2026-07-01"


def dsn() -> str:
    return os.environ.get("DATABASE_URL") or os.environ.get("DATABASE_DSN") or DEFAULT_DSN


def _query(conn, sql: str, params: tuple = ()) -> list[dict[str, Any]]:
    with conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(sql, params)
        return [dict(row) for row in cur.fetchall()]


def _scalar(conn, sql: str, params: tuple = ()) -> Any:
    rows = _query(conn, sql, params)
    if not rows:
        return None
    # A single-column single-row query yields {column: value}; take the value.
    return next(iter(rows[0].values()))


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------


def coverage(conn) -> list[dict[str, Any]]:
    """Matches, completions and date range per competition and season."""
    rows = _query(
        conn,
        """
        SELECT c.name AS competition,
               s.name AS season,
               COUNT(*)::int AS matches,
               SUM(CASE WHEN m.status = 'completed' THEN 1 ELSE 0 END)::int AS completed,
               SUM(CASE WHEN m.status = 'scheduled' THEN 1 ELSE 0 END)::int AS scheduled,
               SUM(CASE WHEN m.status NOT IN ('completed', 'scheduled') THEN 1 ELSE 0 END)::int
                 AS other_status,
               MIN(m.kickoff_at)::date::text AS first_kickoff,
               MAX(m.kickoff_at)::date::text AS last_kickoff,
               COUNT(DISTINCT t.id)::int AS teams
        FROM matches m
        JOIN seasons s ON s.id = m.season_id
        JOIN competitions c ON c.id = s.competition_id
        JOIN seasons se ON se.id = m.season_id
        JOIN (
          SELECT season_id, home_team_id AS id FROM matches
          UNION
          SELECT season_id, away_team_id FROM matches
        ) t ON t.season_id = m.season_id
        GROUP BY c.name, s.name
        ORDER BY c.name, s.name
        """,
    )
    return rows


def duplicates(conn) -> dict[str, Any]:
    """Duplicate fixtures and duplicate provider identifiers.

    Two clubs can legitimately meet more than twice in one season (split-league
    formats), so a repeated ordered pair is reported with its dates rather than
    treated as an error. A repeated pair on the SAME calendar day is a duplicate.
    """
    same_day = _query(
        conn,
        """
        SELECT s.name AS season, h.name AS home, a.name AS away,
               m.kickoff_at::date::text AS day, COUNT(*)::int AS rows
        FROM matches m
        JOIN seasons s ON s.id = m.season_id
        JOIN teams h ON h.id = m.home_team_id
        JOIN teams a ON a.id = m.away_team_id
        GROUP BY s.name, h.name, a.name, m.kickoff_at::date
        HAVING COUNT(*) > 1
        ORDER BY rows DESC, season, home, away
        """,
    )
    repeated_pairs = _query(
        conn,
        """
        SELECT s.name AS season, h.name AS home, a.name AS away, COUNT(*)::int AS meetings
        FROM matches m
        JOIN seasons s ON s.id = m.season_id
        JOIN teams h ON h.id = m.home_team_id
        JOIN teams a ON a.id = m.away_team_id
        GROUP BY s.name, h.name, a.name
        HAVING COUNT(*) > 2
        ORDER BY meetings DESC, season, home, away
        """,
    )
    dup_identifiers = _query(
        conn,
        """
        SELECT provider, external_id, COUNT(*)::int AS rows
        FROM external_identifiers
        WHERE match_id IS NOT NULL
        GROUP BY provider, external_id
        HAVING COUNT(*) > 1
        ORDER BY rows DESC, provider, external_id
        """,
    )
    return {
        "duplicate_fixture_same_day": same_day,
        "repeated_pair_over_two_meetings": repeated_pairs,
        "duplicate_provider_identifiers": dup_identifiers,
    }


def missing_and_invalid(conn) -> dict[str, Any]:
    """Scores, statuses and identities that cannot be trusted."""
    checks = {
        "completed_without_score": """
            SELECT COUNT(*)::int FROM matches
            WHERE status = 'completed' AND (home_score IS NULL OR away_score IS NULL)
        """,
        "negative_score": """
            SELECT COUNT(*)::int FROM matches WHERE home_score < 0 OR away_score < 0
        """,
        "unrealistic_score": """
            SELECT COUNT(*)::int FROM matches WHERE home_score > 15 OR away_score > 15
        """,
        "non_completed_with_score": """
            SELECT COUNT(*)::int FROM matches
            WHERE status <> 'completed' AND (home_score IS NOT NULL OR away_score IS NOT NULL)
        """,
        "same_team_both_sides": """
            SELECT COUNT(*)::int FROM matches WHERE home_team_id = away_team_id
        """,
        "missing_kickoff": """
            SELECT COUNT(*)::int FROM matches WHERE kickoff_at IS NULL
        """,
        "match_without_provider_identifier": """
            SELECT COUNT(*)::int FROM matches m
            WHERE NOT EXISTS (SELECT 1 FROM external_identifiers e WHERE e.match_id = m.id)
        """,
        "team_without_matches": """
            SELECT COUNT(*)::int FROM teams t
            WHERE NOT EXISTS (
              SELECT 1 FROM matches m WHERE m.home_team_id = t.id OR m.away_team_id = t.id
            )
        """,
        "season_without_matches": """
            SELECT COUNT(*)::int FROM seasons s
            WHERE NOT EXISTS (SELECT 1 FROM matches m WHERE m.season_id = s.id)
        """,
    }
    result = {name: int(_scalar(conn, sql) or 0) for name, sql in checks.items()}

    result["unknown_status_values"] = _query(
        conn,
        "SELECT status, COUNT(*)::int AS rows FROM matches "
        "WHERE status NOT IN ('completed', 'scheduled', 'postponed', 'cancelled', 'abandoned') "
        "GROUP BY status ORDER BY status",
    )
    result["status_distribution"] = _query(
        conn,
        "SELECT status, COUNT(*)::int AS rows FROM matches GROUP BY status ORDER BY status",
    )
    result["matches_without_provider_identifier_ids"] = [
        row["id"]
        for row in _query(
            conn,
            """
            SELECT m.id FROM matches m
            WHERE NOT EXISTS (SELECT 1 FROM external_identifiers e WHERE e.match_id = m.id)
            ORDER BY m.id
            """,
        )
    ]
    return result


def kickoffs(conn) -> dict[str, Any]:
    """Suspicious kickoff timestamps: implausible years, midnight, time-less rows.

    football-data.co.uk seasons before 2019/20 do not publish a kickoff time, so
    those rows are stored at 00:00 and are NOT an error — they are counted
    separately so a reader can see why a time-based feature is unavailable there.
    """
    lo, hi = PLAUSIBLE_KICKOFF_YEARS
    implausible = _query(
        conn,
        """
        SELECT m.id, m.kickoff_at::text, s.name AS season
        FROM matches m JOIN seasons s ON s.id = m.season_id
        WHERE EXTRACT(YEAR FROM m.kickoff_at) < %s OR EXTRACT(YEAR FROM m.kickoff_at) > %s
        ORDER BY m.id
        """,
        (lo, hi),
    )
    midnight_by_season = _query(
        conn,
        """
        SELECT s.name AS season, COUNT(*)::int AS midnight_rows,
               COUNT(*) FILTER (WHERE m.status = 'completed')::int AS midnight_completed
        FROM matches m JOIN seasons s ON s.id = m.season_id
        WHERE m.kickoff_at::time = '00:00:00'
        GROUP BY s.name ORDER BY s.name
        """,
    )
    out_of_season = _query(
        conn,
        """
        WITH bounds AS (
          SELECT s.id AS season_id, MIN(m.kickoff_at) AS lo, MAX(m.kickoff_at) AS hi
          FROM matches m JOIN seasons s ON s.id = m.season_id
          GROUP BY s.id
        )
        SELECT m.id, s.name AS season, m.kickoff_at::text
        FROM matches m
        JOIN bounds b ON b.season_id = m.season_id
        JOIN seasons s ON s.id = m.season_id
        WHERE m.kickoff_at < b.lo - INTERVAL '%s days'
           OR m.kickoff_at > b.hi + INTERVAL '%s days'
        ORDER BY m.id
        """,
        (MAX_DAYS_BEFORE_SEASON_START, MAX_DAYS_AFTER_SEASON_END),
    )
    return {
        "implausible_year": implausible,
        "midnight_kickoffs_by_season": midnight_by_season,
        "outside_season_window": out_of_season,
    }


def home_away_consistency(conn) -> dict[str, Any]:
    """Every club's home/away split per season, flagged when wildly asymmetric.

    A club plays every other club once at home and once away, so the difference
    between home and away appearances should never exceed a couple of matches
    (plus split-league replays). A larger gap means some fixtures were imported
    with the sides swapped.
    """
    rows = _query(
        conn,
        """
        WITH played AS (
          SELECT season_id, home_team_id AS team_id, 1 AS home FROM matches
          UNION ALL
          SELECT season_id, away_team_id AS team_id, 0 AS home FROM matches
        )
        SELECT s.name AS season, t.name AS team,
               SUM(played.home)::int AS home_matches,
               (COUNT(*) - SUM(played.home))::int AS away_matches
        FROM played
        JOIN seasons s ON s.id = played.season_id
        JOIN teams t ON t.id = played.team_id
        GROUP BY s.name, t.name
        ORDER BY s.name, t.name
        """,
    )
    imbalanced = [r for r in rows if abs(r["home_matches"] - r["away_matches"]) > 4]
    return {"insertions_checked": len(rows), "imbalanced_clubs": imbalanced}


def provenance(conn) -> dict[str, Any]:
    """Which provider supplied each match, and whether any match has two."""
    by_provider = _query(
        conn,
        """
        SELECT e.provider, COUNT(*)::int AS matches
        FROM external_identifiers e
        WHERE e.match_id IS NOT NULL
        GROUP BY e.provider ORDER BY e.provider
        """,
    )
    multi = _query(
        conn,
        """
        SELECT m.id, s.name AS season, ARRAY_AGG(DISTINCT e.provider ORDER BY e.provider) AS providers
        FROM matches m
        JOIN seasons s ON s.id = m.season_id
        JOIN external_identifiers e ON e.match_id = m.id
        GROUP BY m.id, s.name
        HAVING COUNT(DISTINCT e.provider) > 1
        ORDER BY m.id
        """,
    )
    return {
        "identifiers_by_provider": by_provider,
        "matches_with_multiple_providers": multi,
        "matches_with_multiple_providers_count": len(multi),
    }


def as_of(conn) -> str | None:
    """The most recent match timestamp, a stable stand-in for 'now'."""
    value = _scalar(conn, "SELECT MAX(updated_at)::text FROM matches")
    return str(value) if value is not None else None


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Multi-competition fixture coverage audit (read-only)
# ---------------------------------------------------------------------------

def fixture_coverage(conn) -> list[dict[str, Any]]:
    """Results vs. future fixtures per competition and season, separated.

    Historical coverage and current-season coverage answer different questions: a
    past season should be complete, a current season should have results up to
    today and fixtures after it. A competition whose schedule the provider does not
    publish has zero future fixtures and is reported as such instead of implying
    incompleteness.
    """
    return _query(
        conn,
        """
        WITH today AS (SELECT CURRENT_DATE AS d)
        SELECT c.name AS competition,
               c.country AS country,
               s.name AS season,
               COUNT(*)::int AS matches,
               SUM(CASE WHEN m.status = 'completed' THEN 1 ELSE 0 END)::int AS results,
               SUM(CASE WHEN m.kickoff_at > (SELECT d FROM today) THEN 1 ELSE 0 END)::int
                 AS future_fixtures,
               SUM(CASE WHEN m.status = 'scheduled' AND m.kickoff_at <= (SELECT d FROM today)
                        THEN 1 ELSE 0 END)::int AS stale_scheduled
        FROM matches m
        JOIN seasons s ON s.id = m.season_id
        JOIN competitions c ON c.id = s.competition_id
        GROUP BY c.name, c.country, s.name
        ORDER BY c.name, s.name
        """,
    )


def partial_seasons(conn, expected_matches: dict[str, int] | None = None) -> list[dict[str, Any]]:
    """Seasons whose fixture count is below the size a complete league would have.

    ``expected_matches`` maps a competition name to its full-season fixture count
    (20 clubs -> 380). Competitions without a known size are skipped rather than
    guessed at. A current season is exempt: it is expected to be incomplete.
    """
    if not expected_matches:
        return []
    rows = coverage(conn)
    partial = []
    for row in rows:
        expected = expected_matches.get(row["competition"])
        if expected is None:
            continue
        already_complete = row["completed"] >= expected
        in_progress = row["last_kickoff"] is not None and row["last_kickoff"] >= IN_PROGRESS_FROM
        if row["matches"] < expected and not in_progress and not already_complete:
            partial.append(
                {
                    "competition": row["competition"],
                    "season": row["season"],
                    "matches": row["matches"],
                    "expected": expected,
                }
            )
    return partial


def build_report(conn) -> dict[str, Any]:
    cov = coverage(conn)
    totals = {
        "competitions": len({row["competition"] for row in cov}),
        "seasons": len(cov),
        "matches": sum(row["matches"] for row in cov),
        "completed": sum(row["completed"] for row in cov),
        "scheduled": sum(row["scheduled"] for row in cov),
    }
    status_totals = Counter({row["status"]: row["rows"] for row in missing_and_invalid(conn)["status_distribution"]})
    report = {
        "totals": totals,
        "status_totals": dict(sorted(status_totals.items())),
        "coverage": cov,
        "duplicates": duplicates(conn),
        "integrity": missing_and_invalid(conn),
        "kickoffs": kickoffs(conn),
        "home_away": home_away_consistency(conn),
        "provenance": provenance(conn),
        "fixture_coverage": fixture_coverage(conn),
        "partial_seasons": partial_seasons(conn, FULL_SEASON_FIXTURES),
        "latest_match_update": as_of(conn),
        "gaps": [],
    }
    # Gaps are stated as facts the counts already prove, never as guesses.
    for row in cov:
        if row["other_status"]:
            report["gaps"].append(
                f"{row['competition']} {row['season']}: {row['other_status']} match(es) in a "
                "non-completed, non-scheduled status"
            )
        if row["completed"] == 0:
            report["gaps"].append(
                f"{row['competition']} {row['season']}: no completed results (not usable for training)"
            )
    for entry in report["duplicates"]["duplicate_fixture_same_day"]:
        report["gaps"].append(
            f"duplicate fixture: {entry['season']} {entry['home']} v {entry['away']} on {entry['day']}"
        )
    for entry in report["kickoffs"]["outside_season_window"]:
        report["gaps"].append(
            f"kickoff outside season window: match {entry['id']} ({entry['season']})"
        )
    if report["integrity"]["match_without_provider_identifier"]:
        report["gaps"].append(
            f"{report['integrity']['match_without_provider_identifier']} match(es) with no provider "
            f"identifier: {report['integrity']['matches_without_provider_identifier_ids']}"
        )
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", help="write the report here instead of stdout")
    parser.add_argument("--dsn", default=None, help="PostgreSQL DSN (defaults to DATABASE_URL)")
    args = parser.parse_args(argv)

    if psycopg2 is None:  # pragma: no cover
        print("psycopg2 is required to run the dataset-quality report", file=sys.stderr)
        return 2

    connection = psycopg2.connect(args.dsn or dsn())
    try:
        report = build_report(connection)
    finally:
        connection.close()

    payload = json.dumps(report, indent=2, sort_keys=True, default=str)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            handle.write(payload + "\n")
        print(
            f"dataset quality: {report['totals']['matches']} matches, "
            f"{report['totals']['competitions']} competitions, "
            f"{len(report['gaps'])} recorded gap(s) -> {args.json}"
        )
    else:
        print(payload)
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
