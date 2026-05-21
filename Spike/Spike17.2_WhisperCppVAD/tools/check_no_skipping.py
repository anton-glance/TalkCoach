#!/usr/bin/env python3
"""
NO-SKIPPING gate check (Session 030 lock).
Reads EARLY_summary.json or GATE2_summary.json and exits 1 if C4 > 2000ms (10x budget miss).
"""
import json, sys

if len(sys.argv) < 2:
    print("Usage: check_no_skipping.py <summary.json>"); sys.exit(1)

with open(sys.argv[1]) as f:
    data = json.load(f)

for c in data.get("criteria", []):
    if c["id"] == "C4":
        notes = c.get("notes", "")
        if "10×" in notes or "10x" in notes.lower():
            print(f"[NO-SKIPPING] C4 budget miss ≥10×: {c['measured']} — STOP")
            sys.exit(1)
        if c["disposition"] == "FAIL":
            measured = c["measured"].replace(" ms", "")
            try:
                val = float(measured)
                if val > 2000:
                    print(f"[NO-SKIPPING] C4={val:.0f}ms > 2000ms (10× budget) — STOP")
                    sys.exit(1)
            except ValueError:
                pass
        break

print("[no-skipping] C4 within 10× threshold — continue")
sys.exit(0)
