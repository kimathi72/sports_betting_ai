"""Cache the enriched (feature-bearing) dataset so experiments can reuse it.

Enrichment walks 40k fixtures chronologically and is the slowest step in every
diagnostic; recomputing it for each question is what made iteration painful. The
cache is keyed by the FEATURE_VERSION and the export's size + mtime, so a stale
cache is never silently used after the features change.
"""
import json, os
from ml.app.dataset_export import read_jsonl
from ml.app.features_v2 import FEATURE_VERSION, enrich_history

SRC = "/app/artifacts/evaluation/matches.jsonl"
DST = "/app/artifacts/evaluation/enriched.jsonl"
STAMP = "/app/artifacts/evaluation/enriched.stamp.json"

def _stamp():
    st = os.stat(SRC)
    return {"version": FEATURE_VERSION, "size": st.st_size, "mtime": int(st.st_mtime)}

def load():
    want = _stamp()
    if os.path.exists(DST) and os.path.exists(STAMP):
        if json.load(open(STAMP)) == want:
            return read_jsonl(DST)
    rows = enrich_history(read_jsonl(SRC))
    with open(DST, "w") as h:
        for r in rows:
            h.write(json.dumps(r, default=str) + "\n")
    json.dump(want, open(STAMP, "w"))
    return rows

if __name__ == "__main__":
    rows = load()
    print(f"cached {len(rows)} rows, {sum(1 for r in rows if r.get('label_1x2'))} labelled")
