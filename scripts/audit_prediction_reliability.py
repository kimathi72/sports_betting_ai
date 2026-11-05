#!/usr/bin/env python3
"""Prediction reliability audit (read-only).

Checks the properties that make a stored prediction trustworthy, against the
running Rails API and the development database. It never writes.

  1. provenance consistency: every prediction issued since provenance deployment
     carries the freeze digest, the feature version and the issued kickoff;
  2. market semantics for every current prediction: 1X2/O-U/BTTS sum to 1 within
     five-decimal rounding, double chance equals the 1X2 sums, correct score is a
     six-line truncated view that does not exceed 1;
  3. no prediction precedes the provenance deployment: the 62 historical rows keep
     NULL provenance rather than an invented value;
  4. no duplicate live prediction per (match, market);
  5. no prediction exists for a match at or after its kickoff that is marked
     prospective (i.e. nothing issued after the event is being counted as evidence).
"""
import json
import subprocess
import sys

PSQL = [
    "docker", "compose", "exec", "-T", "postgres", "psql",
    "-U", "sports_ai", "-d", "sports_betting_ai_development", "-t", "-A", "-F", "\t", "-c",
]
TOL = 0.00002


def q(sql):
    out = subprocess.run(PSQL + [sql], capture_output=True, text=True, check=True).stdout
    return [line.split("\t") for line in out.strip().splitlines() if line]


def check(condition, label, detail=""):
    print(f"{'PASS' if condition else 'FAIL'}  {label}{(' — ' + detail) if detail and not condition else ''}")
    return condition


def main():
    ok = True

    # 1. provenance completeness for rows issued after deployment.
    #
    # The boundary is DATA, not a guessed id range: predictions issued before the
    # provenance deployment have no feature_version in model_metadata (the producer
    # did not send one), so "has a feature version" identifies exactly the rows
    # produced by the deployed C2 stack.
    rows = q(
        "select count(*), count(model_freeze_digest), count(issued_kickoff_at), "
        "count(model_metadata->>'feature_version') from predictions "
        "where model_metadata ? 'feature_version'"
    )[0]
    total, with_digest, with_kickoff, with_fv = map(int, rows)
    ok &= check(total > 0, "predictions issued by the provenance-enabled stack exist", f"{total}")
    ok &= check(with_digest == total, "every such prediction has model_freeze_digest",
                f"{with_digest}/{total}")
    ok &= check(with_kickoff == total, "every such prediction has issued_kickoff_at",
                f"{with_kickoff}/{total}")
    ok &= check(with_fv == total, "every such prediction has feature_version", f"{with_fv}/{total}")

    # 2. historical rows stay NULL
    legacy = q(
        "select count(*), count(model_freeze_digest), count(issued_kickoff_at) "
        "from predictions where not (model_metadata ? 'feature_version')"
    )[0]
    l_total, l_digest, l_kick = map(int, legacy)
    ok &= check(l_digest == 0 and l_kick == 0,
                "historical predictions keep NULL provenance (nothing invented)",
                f"{l_total} rows, digests={l_digest}, kickoffs={l_kick}")

    # 3. market semantics on every current prediction
    bad_1x2 = q(
        "select id from predictions where market='1x2' and superseded_at is null "
        f"and abs(home_probability + draw_probability + away_probability - 1) > {TOL}"
    )
    ok &= check(not bad_1x2, "1x2 distributions sum to 1 within rounding")

    # double chance must equal the 1X2 sums of the same match
    dc = q(
        """
        select dc.id, dc.outcomes->>'1x', p.outcomes->>'H', p.outcomes->>'D',
               dc.outcomes->>'x2', p.outcomes->>'A', dc.outcomes->>'12'
        from predictions dc
        join predictions p on p.match_id = dc.match_id and p.market='1x2'
             and p.superseded_at is null
        where dc.market='double_chance' and dc.superseded_at is null
        """
    )
    dc_bad = []
    for row in dc:
        pid, x1, h, d, x2, a, twelve = row
        pairs = [(float(x1), float(h or 0) + float(d or 0)),
                 (float(x2), float(d or 0) + float(a or 0)),
                 (float(twelve), float(h or 0) + float(a or 0))]
        if any(abs(x - y) > 1e-4 for x, y in pairs):
            dc_bad.append(pid)
    ok &= check(not dc_bad, f"double chance derives exactly from 1X2 ({len(dc)} rows)",
                str(dc_bad[:5]))

    binary_rows = q(
        "select id, market, (select sum(v::numeric) from jsonb_each_text(outcomes) as e(k,v)) "
        "from predictions where market in ('over_under_2.5','btts') and superseded_at is null"
    )
    binary_bad = [r[0] for r in binary_rows if abs(float(r[2]) - 1) > TOL]
    ok &= check(not binary_bad, f"binary markets sum to 1 ({len(binary_rows)} rows)", str(binary_bad))

    cs = q(
        "select id, (select count(*) from jsonb_object_keys(outcomes)), "
        "(select sum(v::numeric) from jsonb_each_text(outcomes) as e(k,v)) "
        "from predictions where market='correct_score' and superseded_at is null"
    )
    cs_bad = [r[0] for r in cs if int(r[1]) != 6 or float(r[2]) > 1 + TOL]
    ok &= check(not cs_bad, f"correct score is a six-line truncated view <= 1 ({len(cs)} rows)",
                str(cs_bad))

    # 4. duplicates
    dup = q(
        "select match_id, market, count(*) from predictions where superseded_at is null "
        "group by 1,2 having count(*) > 1"
    )
    ok &= check(not dup, "no duplicate live prediction per (match, market)", str(dup))

    # 5. hindsight
    hindsight = q(
        "select p.id from predictions p join matches m on m.id = p.match_id "
        "where p.generated_at >= m.kickoff_at and p.superseded_at is null"
    )
    # A prediction issued after its fixture's kickoff time is still stored (the
    # system does not silently drop it), but it is NOT prospective evidence:
    # `ProspectiveEligibility` rejects it with `issued_at_or_after_kickoff`. The
    # audit asserts the guarantee that matters — the evaluation gate refuses them.
    # Confirmed here against the live rows rather than assumed.
    if hindsight:
        ids = ",".join(f"'{r[0]}'" for r in hindsight)
        verdict = subprocess.run(
            ["docker", "compose", "exec", "-T", "web", "bin/rails", "runner",
             "Prediction.where(id: [%s]).each { |p| v = Predictions::ProspectiveEligibility.new.call(p); "
             "puts(\"#{p.id} #{v.eligible?} #{v.reason}\") }" % ids],
            capture_output=True, text=True,
        ).stdout.strip().splitlines()
        accepted = [line for line in verdict if line.split()[1] == "true"]
        ok &= check(not accepted,
                    f"predictions issued at/after kickoff ({len(hindsight)}) are refused as evidence",
                    str(accepted[:5]))
    else:
        ok &= check(True, "no live prediction issued at or after kickoff")

    print("\nAUDIT PASSED" if ok else "\nAUDIT FOUND PROBLEMS")
    return 0 if ok else 1


sys.exit(main())
