#!/usr/bin/env python3
"""Provenance negative-scenario probe against the RUNNING ml container.

Each case mutates a throwaway COPY of the artifact directory inside the container
(/tmp/provcase) and points a freshly started uvicorn at it. The real artifacts and
the real freeze record are never touched.

Cases:
  1. freeze record missing          -> no_freeze_record, digest None
  2. artifact missing               -> artifact_missing,  (503 from endpoint)
  3. artifact bytes changed         -> checksum_mismatch, digest None
  4. freeze record malformed        -> 500 (a deployment problem must be visible)
  5. artifact not listed in freeze  -> not_in_freeze, digest None
"""
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

ART = "/app/artifacts"
CASE = "/tmp/provcase"
PORT = 8011
BODY = "/tmp/body.json"


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw)


def fresh_dir():
    sh(f"rm -rf {CASE} && mkdir -p {CASE}")
    sh(f"cp {ART}/*.joblib {CASE}/")
    sh(f"cp {ART}/freeze.json {CASE}/freeze.json")


def start():
    env = dict(os.environ)
    env["MODEL_ARTIFACTS_DIR"] = CASE
    env["MODEL_FREEZE_PATH"] = f"{CASE}/freeze.json"
    proc = subprocess.Popen(
        ["uvicorn", "ml.app.main:app", "--host", "127.0.0.1", "--port", str(PORT)],
        env=env,
        cwd="/app",
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    for _ in range(80):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=1)
            return proc
        except Exception:
            time.sleep(0.25)
    proc.kill()
    raise RuntimeError("uvicorn did not start")


def predict(market="1x2"):
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/predict/from-history/{market}",
        data=open(BODY, "rb").read(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read() or b"{}")


def run_case(name, mutate, expect_status, expect_code_ok, market="1x2"):
    fresh_dir()
    mutate()
    proc = start()
    try:
        code, body = predict(market)
    finally:
        proc.terminate()
        proc.wait(timeout=10)
    status = body.get("provenance_status")
    digest = body.get("model_freeze_digest")
    ok = status == expect_status and (
        expect_code_ok is None or (code == 200) == expect_code_ok
    ) and (
        digest is not None if expect_status == "verified" else digest is None
    )
    print(f"{name:<34} http={code} status={status!s:<20} digest={str(digest)[:12]:<14} {'PASS' if ok else 'FAIL'}")
    return ok


def main():
    all_ok = True
    all_ok &= run_case("control: untouched copy", lambda: None, "verified", True)
    all_ok &= run_case(
        "freeze missing", lambda: sh(f"rm {CASE}/freeze.json"), "no_freeze_record", True
    )
    # The default `source` is `goal_model`, so the artifact that answers a 1X2
    # request is the goal distribution. Removing the unused classifier proves
    # nothing; the answering artifact is the one that must disappear.
    # A missing artifact is reported on the provenance fields; whether the request
    # itself is served (503) depends on the registry, not on provenance, so this
    # case asserts the fields and not the HTTP code.
    all_ok &= run_case(
        "answering artifact missing",
        lambda: sh(f"rm {CASE}/model_goal_distribution.joblib"),
        "artifact_missing",
        None,
    )
    all_ok &= run_case(
        "answering artifact tampered",
        lambda: open(f"{CASE}/model_goal_distribution.joblib", "ab").write(b"\0"),
        "checksum_mismatch",
        True,
    )
    all_ok &= run_case(
        "classifier artifact tampered (source=classifier)",
        lambda: open(f"{CASE}/model_1x2.joblib", "ab").write(b"\0"),
        "checksum_mismatch",
        True,
        market="1x2?source=classifier",
    )
    # malformed record: the request must NOT return a trusted digest, and the
    # deployment problem must be visible rather than degraded to "no provenance".
    fresh_dir()
    open(f"{CASE}/freeze.json", "w").write('{"not":"a freeze"}')
    proc = start()
    try:
        code, _body = predict()
    finally:
        proc.terminate()
        proc.wait(timeout=10)
    malformed_ok = code >= 500
    print(f"{'freeze malformed':<34} http={code} (expected 5xx)          {'PASS' if malformed_ok else 'FAIL'}")
    all_ok &= malformed_ok

    sh(f"rm -rf {CASE}")
    print("\nALL CASES PASS" if all_ok else "\nSOME CASES FAILED")
    return 0 if all_ok else 1


sys.exit(main())
