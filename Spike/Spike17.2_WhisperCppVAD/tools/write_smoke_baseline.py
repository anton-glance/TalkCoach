#!/usr/bin/env python3
"""
Extract smoke baseline median log_prob from quiet_speech_pods_small.csv.
Writes SMOKE_BASELINE.json for C9 gating in the eval.
"""
import csv, json, sys
from pathlib import Path

SPIKE_ROOT = Path(__file__).parent.parent
CSV = SPIKE_ROOT / "results" / "smoke_small.csv"
OUT = SPIKE_ROOT / "results" / "SMOKE_BASELINE.json"

if not CSV.exists():
    print(f"[error] smoke CSV not found: {CSV}"); sys.exit(1)

with open(CSV) as f:
    rows = list(csv.DictReader(f))

confs = [float(r["confidence"]) for r in rows if r.get("confidence") and float(r["confidence"]) >= 0]
if not confs:
    print("[error] no confidence values in smoke CSV"); sys.exit(1)

confs.sort()
median = confs[len(confs) // 2]
OUT.write_text(json.dumps({"medianLogProb": median, "n": len(confs)}, indent=2))
print(f"Smoke baseline: median log_prob={median:.4f} (n={len(confs)}), written to {OUT}")
