#!/usr/bin/env python3
"""
write_smoke_baseline.py — extract SMOKE_BASELINE.json from the bootstrap JSON.
The bootstrap JSON already contains medianLogProb; this just copies it to the
standard SMOKE_BASELINE.json path that Spike17_3Eval reads for C9 scoring.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "..", "results")

model = sys.argv[1] if len(sys.argv) > 1 else "small"
bootstrap_path = os.path.join(RESULTS, f"bootstrap_{model}.json")

if not os.path.exists(bootstrap_path):
    print(f"[error] bootstrap file not found: {bootstrap_path}")
    sys.exit(1)

with open(bootstrap_path) as f:
    bs = json.load(f)

median_log_prob = bs.get("medianLogProb", -1)
baseline = {"medianLogProb": median_log_prob, "model": model, "source": "bootstrap"}

out_path = os.path.join(RESULTS, "SMOKE_BASELINE.json")
with open(out_path, "w") as f:
    json.dump(baseline, f, indent=2)
print(f"[smoke_baseline] medianLogProb={median_log_prob:.3f} written to {out_path}")
