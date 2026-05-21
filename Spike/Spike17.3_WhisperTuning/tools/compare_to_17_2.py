#!/usr/bin/env python3
"""
compare_to_17_2.py — side-by-side comparison of Spike #17.2 vs #17.3 results.

Reads:
  ../Spike17.2_WhisperCppVAD/results/*_small.csv  (baseline)
  results/*_small.csv                              (current)

Outputs COMPARISON.md with per-fixture, per-criterion delta table.
Validates the C4 prediction: kLengthMs=3000 → ~440ms, kLengthMs=1000 → ~120-160ms.
"""
import csv
import json
import os
import sys

FIXTURES = [
    "alternating_pods", "alternating_mac",
    "quiet_speech_pods", "quiet_speech_mac",
    "cafe_noise_pods", "cafe_noise_mac",
    "silence_only_pods", "silence_only_mac",
    "distractors_pods", "distractors_mac",
    "real_world_test",
]

HERE = os.path.dirname(os.path.abspath(__file__))
SPIKE_ROOT = os.path.join(HERE, "..")
RESULTS_17_2 = os.path.join(SPIKE_ROOT, "..", "Spike17.2_WhisperCppVAD", "results")
RESULTS_17_3 = os.path.join(SPIKE_ROOT, "results")


def load_csv(path):
    if not os.path.exists(path):
        return []
    rows = []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
    return rows


def p95(values):
    if not values:
        return None
    s = sorted(values)
    idx = int(len(s) * 0.95)
    return s[min(idx, len(s) - 1)]


def median_conf(rows):
    confs = [float(r["confidence"]) for r in rows
             if r.get("is_confirmed", "0") in ("1", "true", "True")
             and float(r.get("confidence", -1)) >= 0]
    if not confs:
        return None
    confs.sort()
    return confs[len(confs) // 2]


def n_events(rows):
    return len([r for r in rows if r.get("text", "").strip()])


def gaps(rows):
    return [float(r["gap_from_previous_ms"]) for r in rows[1:] if r.get("gap_from_previous_ms")]


def load_bootstrap(results_dir, model="small"):
    path = os.path.join(results_dir, f"bootstrap_{model}.json")
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        return json.load(f)


def load_locked_k(results_dir):
    path = os.path.join(results_dir, "LOCKED_K_LENGTH_MS")
    if os.path.exists(path):
        return open(path).read().strip()
    return "unknown"


lines = []
lines.append("# Spike 17.2 → 17.3 Comparison")
lines.append("")

bs_17_2 = load_bootstrap(RESULTS_17_2)
bs_17_3 = load_bootstrap(RESULTS_17_3)
c4_17_2 = bs_17_2.get("c4FirstTokenMs", "N/A")
c4_17_3 = bs_17_3.get("c4FirstTokenMs", "N/A")
k_17_2 = bs_17_2.get("kLengthMs", 3000)
k_17_3 = bs_17_3.get("kLengthMs", load_locked_k(RESULTS_17_3))
rss_17_2 = bs_17_2.get("rssAfterFirstInferenceMB", "N/A")
rss_17_3 = bs_17_3.get("rssAfterFirstInferenceMB", "N/A")

lines.append("## C4 Prediction Validation")
lines.append("")
lines.append(f"| | kLengthMs | C4 first-token (bootstrap warm) |")
lines.append(f"|---|---|---|")
lines.append(f"| #17.2 | {k_17_2} ms | {c4_17_2 if isinstance(c4_17_2, str) else f'{c4_17_2:.0f} ms'} |")
lines.append(f"| #17.3 | {k_17_3} ms | {c4_17_3 if isinstance(c4_17_3, str) else f'{c4_17_3:.0f} ms'} |")
if isinstance(c4_17_2, (int, float)) and isinstance(c4_17_3, (int, float)) and c4_17_2 > 0:
    ratio = c4_17_3 / c4_17_2
    lines.append(f"| Δ | — | {ratio:.2f}× ({c4_17_3:.0f}/{c4_17_2:.0f}) |")
lines.append("")
lines.append("Prediction: kLengthMs=1000 → C4 ~120–160ms (6–10× improvement over 3000ms)")
lines.append("")

lines.append("## RSS Comparison")
lines.append("")
lines.append(f"| | RSS after first inference |")
lines.append(f"|---|---|")
lines.append(f"| #17.2 (kLengthMs=3000) | {rss_17_2 if isinstance(rss_17_2, str) else f'{rss_17_2:.1f} MB'} |")
lines.append(f"| #17.3 (kLengthMs={k_17_3}) | {rss_17_3 if isinstance(rss_17_3, str) else f'{rss_17_3:.1f} MB'} |")
lines.append("")

lines.append("## Per-fixture Comparison")
lines.append("")
lines.append("| Fixture | Metric | #17.2 (kLengthMs=3000) | #17.3 (kLengthMs=locked) | Δ |")
lines.append("|---------|--------|------------------------|--------------------------|---|")

for fixture in FIXTURES:
    path_17_2 = os.path.join(RESULTS_17_2, f"{fixture}_small.csv")
    path_17_3 = os.path.join(RESULTS_17_3, f"{fixture}_small.csv")
    rows_17_2 = load_csv(path_17_2)
    rows_17_3 = load_csv(path_17_3)

    n2, n3 = n_events(rows_17_2), n_events(rows_17_3)
    p95_2 = p95(gaps(rows_17_2))
    p95_3 = p95(gaps(rows_17_3))
    med2 = median_conf(rows_17_2)
    med3 = median_conf(rows_17_3)

    p95_2_s = f"{p95_2:.0f} ms" if p95_2 is not None else "N/A"
    p95_3_s = f"{p95_3:.0f} ms" if p95_3 is not None else "N/A"
    p95_d = ""
    if p95_2 is not None and p95_3 is not None and p95_2 > 0:
        p95_d = f"{(p95_3 - p95_2) / p95_2 * 100:+.0f}%"

    med2_s = f"{med2:.3f}" if med2 is not None else "N/A"
    med3_s = f"{med3:.3f}" if med3 is not None else "N/A"
    med_d = ""
    if med2 is not None and med3 is not None and med2 > 0:
        med_d = f"{(med3 - med2) / med2 * 100:+.1f}%"

    n_d = f"{n3 - n2:+d}" if n2 > 0 else ""

    lines.append(f"| **{fixture}** | C5 p95 gap | {p95_2_s} | {p95_3_s} | {p95_d} |")
    lines.append(f"| | C9 median conf | {med2_s} | {med3_s} | {med_d} |")
    lines.append(f"| | N events | {n2} | {n3} | {n_d} |")

lines.append("")
lines.append(f"_Generated by tools/compare_to_17_2.py_")

out_path = os.path.join(SPIKE_ROOT, "COMPARISON.md")
with open(out_path, "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"[compare] written to {out_path}")
