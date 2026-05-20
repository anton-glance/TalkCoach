#!/bin/bash
# Spike 17.1.5 — StreamingEouAsrManager + Parakeet 120M EOU: full evaluation run.
# Usage:  ./run_all.sh
#
# GATE 1 (Lock 2): runs all three chunk sizes (160ms, 320ms, 1280ms) against all
# fixtures and measures C4/C5/C8 for each. Writes GATE1_PASS.md or GATE1_FAIL.md.
# If all three sizes fail C4/C5/C8, stops before Gate 2.
#
# GATE 2: runs full 12-criteria eval using the best passing chunk size.
# Generates summary.json + comparison.md.
#
# Outputs:
#   results/bootstrap_<N>ms.json      — model load per chunk size
#   results/<fixture>_<N>ms.csv       — per-fixture token timeline per chunk size
#   results/<fixture>_<N>ms.json      — per-clip eval per chunk size
#   results/summary.json              — final verdict (Gate 2 chunk size)
#   GATE1_PASS.md / GATE1_FAIL.md
#   REPORT.md                         — Phase 3 output (written after script)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RECORDINGS="$SCRIPT_DIR/recordings"
RESULTS="$SCRIPT_DIR/results"

mkdir -p "$RESULTS"

FIXTURES=(
    alternating_pods
    alternating_mac
    cafe_noise_pods
    cafe_noise_mac
    distractors_pods
    distractors_mac
    quiet_speech_pods
    quiet_speech_mac
    silence_only_pods
    silence_only_mac
)

# ────────────────────────────────────────────────────────────
echo "=== Phase 0: Build ==="
swift build -c release 2>&1 | tee "$RESULTS/build.log" || {
    echo "FATAL: swift build failed — see results/build.log"
    cat > "$RESULTS/bootstrap_160ms.json" <<'EOFJ'
{
  "errorDescription": "swift build failed — see results/build.log",
  "loadDurationMs": 0,
  "modelLoadSuccess": false,
  "peakRSSMB": 0
}
EOFJ
    exit 1
}

CLI=".build/release/Spike17_1_5CLI"
EVAL=".build/release/Spike17_1_5Eval"

# ────────────────────────────────────────────────────────────
# Helper: process all fixtures for a given chunk size.
# Writes CSVs to results/<fixture>_<N>ms.csv.
run_fixtures() {
    local SIZE=$1
    echo ""
    echo "--- Processing fixtures at ${SIZE}ms ---"

    local BOOTSTRAP="$RESULTS/bootstrap_${SIZE}ms.json"

    # Bootstrap (model download + load)
    if [ -f "$BOOTSTRAP" ] && python3 -c "import json,sys; d=json.load(open('$BOOTSTRAP')); sys.exit(0 if d.get('modelLoadSuccess') else 1)" 2>/dev/null; then
        echo "INFO: bootstrap_${SIZE}ms.json present — skipping download."
    else
        "$CLI" --bootstrap-only --chunk-size "$SIZE" 2>&1 | tee "$RESULTS/bootstrap_${SIZE}ms.stderr"
        if ! python3 -c "import json,sys; d=json.load(open('$BOOTSTRAP')); sys.exit(0 if d.get('modelLoadSuccess') else 1)" 2>/dev/null; then
            echo "FATAL: model load failed for ${SIZE}ms. See results/bootstrap_${SIZE}ms.json."
            return 1
        fi
    fi

    for FIXTURE in "${FIXTURES[@]}"; do
        CAF="$RECORDINGS/${FIXTURE}.caf"
        CSV="$RESULTS/${FIXTURE}_${SIZE}ms.csv"
        if [ ! -f "$CAF" ]; then
            echo "WARN: $CAF not found, skipping."
            continue
        fi
        if [ -f "$CSV" ]; then
            echo "  $FIXTURE (cached)"
            continue
        fi
        echo "  Processing $FIXTURE..."
        "$CLI" "$CAF" --output "$CSV" --chunk-size "$SIZE" \
            2>"$RESULTS/${FIXTURE}_${SIZE}ms.stderr" || {
            echo "  ERROR: CLI failed for $FIXTURE at ${SIZE}ms (exit $?). Continuing."
        }
    done

    # real_world_test
    RW_CAF="$RECORDINGS/real_world_test.caf"
    RW_CSV="$RESULTS/real_world_test_${SIZE}ms.csv"
    if [ -f "$RW_CAF" ] && [ ! -f "$RW_CSV" ]; then
        echo "  Processing real_world_test..."
        "$CLI" "$RW_CAF" --output "$RW_CSV" --chunk-size "$SIZE" \
            2>"$RESULTS/real_world_test_${SIZE}ms.stderr" || {
            echo "  ERROR: CLI failed for real_world_test at ${SIZE}ms. Continuing."
        }
    fi
}

# Helper: run eval on fixture CSVs for a given chunk size.
# Creates per-clip JSONs named <fixture>_<N>ms.json with CSV paths renamed.
run_eval() {
    local SIZE=$1
    echo ""
    echo "--- Evaluating clips at ${SIZE}ms ---"

    # Create symlinks with canonical names for the eval tool
    # (Spike17_1_5Eval expects <fixture>.csv, not <fixture>_<N>ms.csv)
    local EVAL_DIR="$RESULTS/eval_${SIZE}ms"
    mkdir -p "$EVAL_DIR"
    cp "$RESULTS/bootstrap_${SIZE}ms.json" "$EVAL_DIR/bootstrap.json" 2>/dev/null || true
    for FIXTURE in "${FIXTURES[@]}" real_world_test; do
        SRC="$RESULTS/${FIXTURE}_${SIZE}ms.csv"
        if [ -f "$SRC" ]; then
            cp "$SRC" "$EVAL_DIR/${FIXTURE}.csv"
        fi
    done

    for FIXTURE in "${FIXTURES[@]}" real_world_test; do
        CSV="$EVAL_DIR/${FIXTURE}.csv"
        if [ ! -f "$CSV" ]; then continue; fi
        "$EVAL" clip "$FIXTURE" --csv "$CSV" 2>/dev/null || true
    done

    "$EVAL" summarize \
        --results-dir "$EVAL_DIR" \
        --bootstrap "$EVAL_DIR/bootstrap.json"

    echo "$EVAL_DIR/summary.json"
}

# Helper: extract C4/C5/C8 dispositions from summary.json
gate1_check() {
    local SUMMARY=$1
    python3 - "$SUMMARY" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    criteria = {c['id']: c for c in d.get('criteria', [])}
    c4 = criteria.get(4, {}).get('disposition', 'FAIL')
    c5 = criteria.get(5, {}).get('disposition', 'FAIL')
    c8 = criteria.get(8, {}).get('disposition', 'FAIL')
    print(f"C4={c4} C5={c5} C8={c8}")
    # PASS or WARN both count as gate-passing
    ok = all(x in ('PASS', 'WARN') for x in [c4, c5, c8])
    sys.exit(0 if ok else 1)
except Exception as e:
    print(f"ERROR reading summary: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# ────────────────────────────────────────────────────────────
echo ""
echo "=== GATE 1: Chunk-size sweep (Lock 2) ==="

BEST_SIZE=""
declare -A GATE1_RESULTS  # SIZE -> "C4=... C5=... C8=..."

for SIZE in 160 320 1280; do
    echo ""
    echo ">>> Testing ${SIZE}ms chunk size..."

    # Abort-early check: if 160ms misses by 10× on C4, no point sweeping further
    if [ "$SIZE" == "320" ] && [ -n "${GATE1_RESULTS[160]+x}" ]; then
        PREV="${GATE1_RESULTS[160]}"
        # Extract C4 measured value — check for extreme miss
        C4_VAL=$(python3 - "$RESULTS/eval_160ms/summary.json" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    criteria = {c['id']: c for c in d.get('criteria', [])}
    measured = criteria.get(4, {}).get('measured', '0ms')
    # Extract first number from measured string
    import re
    m = re.search(r'(\d+)', measured)
    print(int(m.group(1)) if m else 0)
except:
    print(0)
PYEOF
        )
        if [ "$C4_VAL" -gt 2000 ] 2>/dev/null; then
            echo "ABORT: 160ms C4=${C4_VAL}ms — 10× budget miss. StreamingEou batches internally."
            echo "Skipping 320ms and 1280ms sweeps."
            break
        fi
    fi

    run_fixtures "$SIZE" || {
        GATE1_RESULTS[$SIZE]="model-load-failed"
        continue
    }
    SUMMARY_DIR=$(run_eval "$SIZE")
    SUMMARY="$RESULTS/eval_${SIZE}ms/summary.json"

    DISP=$(gate1_check "$SUMMARY" || true)
    GATE1_RESULTS[$SIZE]="$DISP"
    echo "  $SIZE ms: $DISP"

    if gate1_check "$SUMMARY" 2>/dev/null; then
        if [ -z "$BEST_SIZE" ]; then
            BEST_SIZE="$SIZE"
            echo "  >>> $SIZE ms PASSES Gate 1 (lowest-latency passing size)"
        fi
    fi
done

# ────────────────────────────────────────────────────────────
echo ""
echo "=== Generating Gate 1 report ==="

# Build gate 1 report
GATE1_ALL_FAIL=true
for SIZE in 160 320 1280; do
    if [ -f "$RESULTS/eval_${SIZE}ms/summary.json" ]; then
        if gate1_check "$RESULTS/eval_${SIZE}ms/summary.json" 2>/dev/null; then
            GATE1_ALL_FAIL=false
        fi
    fi
done

if $GATE1_ALL_FAIL; then
    echo "GATE 1 FAIL — all chunk sizes failed C4/C5/C8"
    python3 - "${GATE1_RESULTS[@]+"${!GATE1_RESULTS[@]}"}" <<'PYEOF' > GATE1_FAIL.md
import json, sys, os

results_dir = "results"
sizes = [160, 320, 1280]

lines = [
    "# GATE 1 FAIL — StreamingEouAsrManager Latency Validation",
    "",
    "All three chunk sizes (160ms, 320ms, 1280ms) failed C4/C5/C8.",
    "",
    "## Per-Chunk-Size Results",
    "",
    "| Chunk | C4 First-update | C5 inter-update p95 | C8 VAD accuracy | Gate 1 |",
    "|-------|----------------|---------------------|-----------------|--------|",
]

for size in sizes:
    path = f"{results_dir}/eval_{size}ms/summary.json"
    if not os.path.exists(path):
        lines.append(f"| {size}ms | N/A | N/A | N/A | FAIL (no data) |")
        continue
    d = json.load(open(path))
    criteria = {c['id']: c for c in d.get('criteria', [])}
    c4 = criteria.get(4, {})
    c5 = criteria.get(5, {})
    c8 = criteria.get(8, {})
    ok = all(x.get('disposition', 'FAIL') in ('PASS', 'WARN')
             for x in [c4, c5, c8])
    lines.append(
        f"| {size}ms "
        f"| {c4.get('measured', 'N/A')} ({c4.get('disposition', '?')}) "
        f"| {c5.get('measured', 'N/A')} ({c5.get('disposition', '?')}) "
        f"| {c8.get('measured', 'N/A')} ({c8.get('disposition', '?')}) "
        f"| {'PASS' if ok else 'FAIL'} |"
    )

lines += [
    "",
    "## Architectural Root Cause",
    "",
    "TODO: fill in after examining stderr logs and token timelines.",
    "",
    "## Recommendation",
    "",
    "Escalate to whisper.cpp or Sherpa-ONNX. See Spike #17.2 scope.",
]
print("\n".join(lines))
PYEOF
    echo "See GATE1_FAIL.md for details."
    echo ""
    echo "GATE 1 FAIL — stopping. Do not proceed to Gate 2."
    exit 0
else
    python3 - <<PYEOF > GATE1_PASS.md
import json, os

results_dir = "results"
sizes = [160, 320, 1280]
best = "$BEST_SIZE"

lines = [
    "# GATE 1 PASS — StreamingEouAsrManager Latency Validation",
    "",
    f"Best chunk size for Gate 2: **{best}ms** (lowest latency that passes C4/C5/C8).",
    "",
    "## Chunk-Size Sweep Results (Lock 2)",
    "",
    "| Chunk | C4 First-update median | C5 inter-update p95 | C8 VAD accuracy | Gate 1 |",
    "|-------|------------------------|---------------------|-----------------|--------|",
]

for size in sizes:
    path = f"{results_dir}/eval_{size}ms/summary.json"
    if not os.path.exists(path):
        lines.append(f"| {size}ms | N/A | N/A | N/A | no data |")
        continue
    d = json.load(open(path))
    criteria = {c['id']: c for c in d.get('criteria', [])}
    c4 = criteria.get(4, {})
    c5 = criteria.get(5, {})
    c8 = criteria.get(8, {})
    ok = all(x.get('disposition', 'FAIL') in ('PASS', 'WARN')
             for x in [c4, c5, c8])
    lines.append(
        f"| {size}ms "
        f"| {c4.get('measured', 'N/A')} ({c4.get('disposition', '?')}) "
        f"| {c5.get('measured', 'N/A')} ({c5.get('disposition', '?')}) "
        f"| {c8.get('measured', 'N/A')} ({c8.get('disposition', '?')}) "
        f"| {'PASS' if ok else 'FAIL'} |"
    )

lines += [
    "",
    "Proceeding to Gate 2 with **" + best + "ms** chunk size.",
]
print("\n".join(lines))
PYEOF
    echo "See GATE1_PASS.md"
fi

# ────────────────────────────────────────────────────────────
echo ""
echo "=== GATE 2: Full 12-criteria evaluation (${BEST_SIZE}ms) ==="

# Copy the best-size eval dir's summary to the canonical results location
cp "$RESULTS/eval_${BEST_SIZE}ms/summary.json" "$RESULTS/summary.json"
cp "$RESULTS/bootstrap_${BEST_SIZE}ms.json" "$RESULTS/bootstrap.json"

# Also write canonical CSV names (no size suffix) for Gate 2 final report
for FIXTURE in "${FIXTURES[@]}" real_world_test; do
    SRC="$RESULTS/${FIXTURE}_${BEST_SIZE}ms.csv"
    DST="$RESULTS/${FIXTURE}.csv"
    if [ -f "$SRC" ] && [ ! -f "$DST" ]; then
        cp "$SRC" "$DST"
    fi
done

echo ""
echo "=== Phase: Side-by-side comparison vs Spike #17.1 ==="
PREV_RESULTS="../Spike17.1_ParakeetFeasibility/results"
if [ -d "$PREV_RESULTS" ]; then
    python3 tools/compare_to_17_1.py "$PREV_RESULTS" "$RESULTS" > "$RESULTS/comparison.md" && \
        echo "INFO: wrote results/comparison.md"
else
    echo "WARN: $PREV_RESULTS not found — skipping comparison"
fi

echo ""
echo "=== Done ==="
VERDICT=$(python3 -c "import json; d=json.load(open('$RESULTS/summary.json')); print(d['verdict'])" 2>/dev/null || echo "UNKNOWN")
echo "Verdict: $VERDICT"
echo "See results/summary.json for details."
echo ""
echo "Next step: write REPORT.md (Phase 3)."
