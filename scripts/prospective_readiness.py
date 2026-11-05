#!/usr/bin/env python3
"""Prospective capture readiness report (read-only).

Answers one question: if a fixture finished tomorrow, would the prediction we
issued before kickoff count as prospective evidence?

Nothing is written. Every number comes from the development database.
"""
import subprocess
import sys

PSQL = ["docker", "compose", "exec", "-T", "postgres", "psql",
        "-U", "sports_ai", "-d", "sports_betting_ai_development",
        "-t", "-A", "-F", "|", "-c"]


def q(sql):
    out = subprocess.run(PSQL + [sql], capture_output=True, text=True, check=True).stdout
    return [line.split("|") for line in out.strip().splitlines() if line]


def row(sql):
    return q(sql)[0]


def line(label, value, note=""):
    print(f"  {label:<46} {value}{('   ' + note) if note else ''}")


def main():
    print("PROSPECTIVE CAPTURE READINESS")
    print("=" * 78)

    total = int(row("select count(*) from predictions")[0])
    with_digest = int(row("select count(*) from predictions where model_freeze_digest is not null")[0])
    with_fv = int(row("select count(*) from predictions where model_metadata ? 'feature_version'")[0])
    with_kick = int(row("select count(*) from predictions where issued_kickoff_at is not null")[0])

    print("\n1. Provenance coverage")
    line("predictions stored", total)
    line("with model_freeze_digest", with_digest, f"({with_digest*100//max(total,1)}%)")
    line("with feature_version", with_fv)
    line("with issued_kickoff_at", with_kick, )
    line("legacy rows (no provenance, must stay ineligible)", total - with_fv)

    print("\n2. Live predictions on fixtures that have not kicked off")
    pending = q("""
        select p.market, count(*), sum(case when p.model_freeze_digest is not null then 1 else 0 end)
        from predictions p join matches m on m.id = p.match_id
        where p.superseded_at is null and m.status = 'scheduled' and m.kickoff_at > now()
        group by 1 order by 1
    """)
    if pending:
        for market, count, with_d in pending:
            line(f"  {market}", f"{count} rows, {with_d} with digest")
    else:
        line("nothing waiting", 0)

    print("\n3. Predictions that will NEVER be evidence")
    late = q("""
        select p.id, p.match_id, p.market, p.generated_at, m.kickoff_at,
               case when p.model_freeze_digest is null then 'no digest' else 'has digest' end
        from predictions p join matches m on m.id = p.match_id
        where p.superseded_at is null and p.generated_at >= m.kickoff_at
        order by p.id
    """)
    line("issued at/after kickoff", len(late))
    for pid, mid, market, gen, kick, digest in late[:12]:
        print(f"      prediction {pid:<4} match {mid:<6} {market:<14} issued {gen[:16]} kickoff {kick[:16]}  {digest}")
    if len(late) > 12:
        print(f"      … and {len(late) - 12} more")

    rescheduled = q("""
        select count(*) from predictions
        where superseded_at is null and issued_kickoff_at is not null
          and match_id in (select id from matches)
    """)
    drift = q("""
        select p.id, p.match_id from predictions p join matches m on m.id = p.match_id
        where p.superseded_at is null and p.issued_kickoff_at is not null
          and p.issued_kickoff_at <> m.kickoff_at
    """)
    line("issued against a kickoff that has since changed", len(drift))
    for pid, mid in drift[:10]:
        print(f"      prediction {pid} match {mid} — rejected as kickoff_changed_since_issue")

    print("\n4. Scoring state")
    records = int(row("select count(*) from prospective_evaluation_records")[0])
    scorable = int(row("""
        select count(*) from predictions p join matches m on m.id = p.match_id
        where p.superseded_at is null and m.status = 'completed'
          and p.model_freeze_digest is not null
          and p.generated_at < m.kickoff_at
          and not exists (select 1 from prospective_evaluation_records r where r.prediction_id = p.id)
    """)[0])
    line("evaluation records written", records)
    line("currently scorable (not yet scored)", scorable)

    print("\n5. Fixtures")
    stale = int(row("select count(*) from matches where status = 'scheduled' and kickoff_at < now()")[0])
    upcoming = int(row("select count(*) from matches where status = 'scheduled' and kickoff_at > now()")[0])
    completed = int(row("select count(*) from matches where status = 'completed'")[0])
    line("completed", completed)
    line("scheduled in the future", upcoming)
    line("scheduled but already kicked off (stale status)", stale)

    print("\n" + "=" * 78)
    print("VERDICT")
    evidence = records
    if evidence == 0:
        print("  Prospective evidence: NONE yet.")
    else:
        print(f"  Prospective evidence: {evidence} scored prediction(s).")
    print("  Capture readiness (infrastructure): READY")
    print("  Capture readiness (evidence):       INSUFFICIENT")
    print("  INSUFFICIENT EVIDENCE — NO BETTING RECOMMENDATION")
    return 0


sys.exit(main())
