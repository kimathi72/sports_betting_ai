#!/usr/bin/env python3
"""End-to-end prediction sweep: Rails API -> FastAPI -> Rails -> JSON.

Run from the host with the stack up. It issues POST /api/v1/predictions for one
upcoming fixture per competition, all five markets, and asserts the market
semantics the project documents:

  1x2            sums to 1
  over_under_2.5 sums to 1
  btts           sums to 1
  double_chance  sums to 2 (overlapping events), and each value equals the
                 corresponding 1X2 sum EXACTLY
  correct_score  six lines, truncated view, each in [0,1], total <= 1

Exit code is 0 only when every check passes.
"""
import json
import sys
import urllib.request

RAILS = "http://localhost:3000"
MARKETS = ["1x2", "over_under_2.5", "btts", "double_chance", "correct_score"]
TOL = 1e-4


def get(path):
    with urllib.request.urlopen(RAILS + path, timeout=30) as r:
        return json.loads(r.read())


def post(path, payload):
    req = urllib.request.Request(
        RAILS + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as exc:
        raw = exc.read() or b"{}"
        try:
            return exc.code, json.loads(raw)
        except ValueError:
            return exc.code, {"raw": raw[:400].decode("utf-8", "replace")}


def upcoming_per_competition():
    """One scheduled, not-yet-kicked-off fixture per competition."""
    comps = get("/api/v1/competitions")
    out = []
    for comp in comps:
        seasons = get(f"/api/v1/seasons?competition_id={comp['id']}")
        label = comp.get("current_season")
        season = next((s for s in seasons if s.get("name") == label), None)
        if season is None:
            continue
        rows = get(f"/api/v1/matches?season_id={season['id']}&status=scheduled&limit=500")
        if rows:
            out.append((comp["code"], comp["name"], rows[0]["id"]))
    return out


def check_market(market, probs, one_x2):
    errs = []
    vals = list(probs.values())
    if any(v < 0 or v > 1 for v in vals):
        errs.append(f"{market}: probability outside [0,1]")
    if market in ("1x2", "over_under_2.5", "btts"):
        if abs(sum(vals) - 1) > TOL:
            errs.append(f"{market}: sums to {sum(vals):.5f}, expected 1")
    if market == "double_chance":
        if abs(sum(vals) - 2) > TOL:
            errs.append(f"{market}: sums to {sum(vals):.5f}, expected 2 (overlapping)")
        if one_x2:
            h, d, a = one_x2["H"], one_x2["D"], one_x2["A"]
            for key, want in (("1x", h + d), ("x2", d + a), ("12", h + a)):
                if abs(probs[key] - want) > TOL:
                    errs.append(f"{market}: {key}={probs[key]:.5f} != 1X2 sum {want:.5f}")
    if market == "correct_score":
        if len(probs) != 6:
            errs.append(f"{market}: {len(probs)} lines, expected 6 (top-six view)")
        if sum(vals) > 1 + TOL:
            errs.append(f"{market}: truncated total {sum(vals):.5f} exceeds 1")
    return errs


def main():
    failures = 0
    fixtures = upcoming_per_competition()
    print(f"competitions with upcoming fixtures: {len(fixtures)}")
    for code, name, match_id in fixtures:
        status, body = post("/api/v1/predictions", {"match_id": match_id, "markets": MARKETS})
        if status not in (200, 201):
            print(f"{code:<4} match {match_id}: HTTP {status} {str(body)[:160]}")
            failures += 1
            continue
        preds = {p["market"]: p for p in body["predictions"]}
        errs = []
        if sorted(preds) != sorted(MARKETS):
            errs.append(f"markets returned {sorted(preds)}")
        one_x2 = preds.get("1x2", {}).get("probabilities")
        for market in MARKETS:
            if market in preds:
                errs += check_market(market, preds[market]["probabilities"], one_x2)
        if body.get("errors"):
            errs.append(f"per-market errors: {body['errors']}")
        verdict = "OK  " if not errs else "FAIL"
        print(f"{code:<4} match {match_id:<6} {verdict} 1x2={ {k: round(v, 4) for k, v in (one_x2 or {}).items()} }")
        for e in errs:
            print(f"       {e}")
        failures += len(errs)
    print(f"\n{'ALL MARKETS OK' if failures == 0 else str(failures) + ' FAILURE(S)'}")
    return 0 if failures == 0 else 1


sys.exit(main())
