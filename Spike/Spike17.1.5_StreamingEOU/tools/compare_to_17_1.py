#!/usr/bin/env python3
"""Side-by-side comparison of Spike #17.1 vs #17.1.5 token timelines.

Usage:
    python3 tools/compare_to_17_1.py <17.1-results-dir> <17.1.5-results-dir>

Outputs markdown to stdout; redirect to results/comparison.md.
"""
import csv
import sys
import os

FIXTURES = [
    "real_world_test",
    "cafe_noise_pods",
    "alternating_pods",
]


def read_csv(path):
    if not os.path.exists(path):
        return []
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                rows.append({
                    "index": int(row.get("update_index", 0)),
                    "ms": float(row.get("emission_ms", 0)),
                    "gap": float(row.get("gap_from_previous_ms", 0)),
                    "text": row.get("text", "").strip(),
                    "confirmed": row.get("is_confirmed", "false").strip().lower() == "true",
                    "confidence": float(row.get("confidence", -1.0)),
                })
            except (ValueError, KeyError):
                continue
    return rows


def truncate(text, n=50):
    return text[:n] + "…" if len(text) > n else text


def format_table(fixture, rows_17_1, rows_17_1_5, n=12):
    """Build a markdown comparison table for the first n updates."""
    lines = []
    lines.append(f"### {fixture}")
    lines.append("")
    lines.append(
        f"| # | #17.1 time | #17.1 text (600M TDT) | #17.1.5 time | #17.1.5 text (120M EOU) |"
    )
    lines.append("|---|------------|----------------------|--------------|--------------------------|")

    maxn = max(len(rows_17_1), len(rows_17_1_5), n)
    shown = min(maxn, n)

    for i in range(shown):
        r1 = rows_17_1[i] if i < len(rows_17_1) else None
        r2 = rows_17_1_5[i] if i < len(rows_17_1_5) else None

        t1 = f"{r1['ms']:.0f}ms" if r1 else "—"
        txt1 = truncate(r1["text"]) if r1 else "—"
        t2 = f"{r2['ms']:.0f}ms" if r2 else "—"
        txt2 = truncate(r2["text"]) if r2 else "—"

        lines.append(f"| {i} | {t1} | {txt1} | {t2} | {txt2} |")

    return lines


def latency_stats(rows):
    if not rows:
        return "no data"
    first = rows[0]["ms"]
    gaps = [r["gap"] for r in rows[1:] if r["gap"] > 0]
    p50 = sorted(gaps)[len(gaps) // 2] if gaps else 0
    p95_idx = int(0.95 * max(len(gaps) - 1, 0))
    p95 = sorted(gaps)[p95_idx] if gaps else 0
    return (
        f"first={first:.0f}ms; "
        f"gap p50={p50:.0f}ms; "
        f"gap p95={p95:.0f}ms; "
        f"total updates={len(rows)}"
    )


def confidence_stats(rows):
    confs = [r["confidence"] for r in rows if r["confidence"] >= 0]
    if not confs:
        return "no confidence data (RNNT sentinel -1.0)"
    confs.sort()
    median = confs[len(confs) // 2]
    p25 = confs[len(confs) // 4]
    p75 = confs[3 * len(confs) // 4]
    return f"median={median:.2f} p25={p25:.2f} p75={p75:.2f} (n={len(confs)})"


def main():
    if len(sys.argv) < 3:
        print("Usage: compare_to_17_1.py <17.1-results-dir> <17.1.5-results-dir>",
              file=sys.stderr)
        sys.exit(1)

    dir_17_1 = sys.argv[1]
    dir_17_1_5 = sys.argv[2]

    out = []
    out.append("# Side-by-Side Token Comparison: Spike #17.1 vs #17.1.5")
    out.append("")
    out.append("**#17.1**: SlidingWindowAsrManager + Parakeet TDT v3 600M (15s batch, C4 FAIL)")
    out.append("**#17.1.5**: StreamingEouAsrManager + Parakeet EOU 120M (160ms chunks, real-time)")
    out.append("")
    out.append("Comparison shows first 12 updates per fixture. Accuracy is qualitative.")
    out.append("")

    for fixture in FIXTURES:
        rows_17_1 = read_csv(os.path.join(dir_17_1, f"{fixture}.csv"))
        rows_17_1_5 = read_csv(os.path.join(dir_17_1_5, f"{fixture}.csv"))

        out.append(f"---")
        out.extend(format_table(fixture, rows_17_1, rows_17_1_5, n=12))
        out.append("")
        out.append(f"**#17.1 latency**: {latency_stats(rows_17_1)}")
        out.append(f"**#17.1.5 latency**: {latency_stats(rows_17_1_5)}")
        out.append(f"**#17.1 confidence**: {confidence_stats(rows_17_1)}")
        out.append(f"**#17.1.5 confidence**: {confidence_stats(rows_17_1_5)}")
        out.append("")

    # Confidence distribution summary across all fixtures
    out.append("---")
    out.append("## Confidence Distribution Summary")
    out.append("")
    out.append("| Metric | #17.1 (600M TDT) | #17.1.5 (120M EOU) |")
    out.append("|--------|------------------|---------------------|")

    all_17_1_confs = []
    all_17_1_5_confs = []
    for fixture in FIXTURES + ["quiet_speech_pods", "distractors_pods"]:
        r1 = read_csv(os.path.join(dir_17_1, f"{fixture}.csv"))
        r2 = read_csv(os.path.join(dir_17_1_5, f"{fixture}.csv"))
        all_17_1_confs.extend(x["confidence"] for x in r1 if x["confidence"] >= 0)
        all_17_1_5_confs.extend(x["confidence"] for x in r2 if x["confidence"] >= 0)

    def stat_row(label, vals17_1, vals17_1_5, fmt="{:.2f}"):
        if not vals17_1:
            s1 = "N/A"
        else:
            v = sorted(vals17_1)
            s1 = fmt.format(v[len(v) // 2])
        if not vals17_1_5:
            s2 = "N/A (RNNT: no per-chunk confidence)"
        else:
            v = sorted(vals17_1_5)
            s2 = fmt.format(v[len(v) // 2])
        return f"| {label} | {s1} | {s2} |"

    out.append(stat_row("Median confidence", all_17_1_confs, all_17_1_5_confs))
    if all_17_1_confs:
        s = sorted(all_17_1_confs)
        p25 = s[len(s) // 4]
        p75 = s[3 * len(s) // 4]
        out.append(f"| p25/p75 confidence | {p25:.2f} / {p75:.2f} | N/A |")
    out.append(f"| Updates with confidence | {len(all_17_1_confs)} | {len(all_17_1_5_confs)} |")
    out.append("")

    print("\n".join(out))


if __name__ == "__main__":
    main()
