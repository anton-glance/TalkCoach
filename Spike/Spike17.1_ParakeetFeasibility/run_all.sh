#!/bin/bash
# Spike 17.1 — Parakeet TDT v3 via FluidAudio: full evaluation run.
# Usage:  ./run_all.sh
# First run: triggers FluidAudio model download (~614 MB, ~30s on broadband).
# Subsequent runs: fast (model cached on disk by FluidAudio).
#
# Outputs:
#   results/bootstrap.json      — model load result + peak RSS
#   results/<fixture>.csv       — per-fixture token timeline
#   results/<fixture>.json      — per-clip evaluation
#   results/summary.json        — verdict + 12 criteria + V1-V10 answers

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RECORDINGS="$SCRIPT_DIR/recordings"
RESULTS="$SCRIPT_DIR/results"
BOOTSTRAP="$RESULTS/bootstrap.json"

mkdir -p "$RESULTS"

echo "=== Phase 0: Build ==="
swift build -c release 2>&1 | tee "$RESULTS/build.log" || {
    echo "FATAL: swift build failed — see results/build.log"
    # Write a synthetic bootstrap indicating build failure for Criterion 1
    cat > "$BOOTSTRAP" <<'EOF'
{
  "errorDescription": "swift build failed — see results/build.log",
  "loadDurationMs": 0,
  "modelLoadSuccess": false,
  "peakRSSMB": 0
}
EOF
    exit 1
}

CLI=".build/release/Spike17_1CLI"
EVAL=".build/release/Spike17_1Eval"

echo ""
echo "=== Phase 1: Bootstrap (model download + load) ==="
if [ -f "$BOOTSTRAP" ] && python3 -c "import json,sys; d=json.load(open('$BOOTSTRAP')); sys.exit(0 if d.get('modelLoadSuccess') else 1)" 2>/dev/null; then
    echo "INFO: bootstrap.json present and modelLoadSuccess=true — skipping download."
else
    "$CLI" --bootstrap-only 2>&1 | tee "$RESULTS/bootstrap.stderr"
    if ! python3 -c "import json,sys; d=json.load(open('$BOOTSTRAP')); sys.exit(0 if d.get('modelLoadSuccess') else 1)" 2>/dev/null; then
        echo "FATAL: model load failed. See results/bootstrap.json and results/bootstrap.stderr."
        exit 1
    fi
fi

echo ""
echo "=== Phase 2: Process fixtures ==="

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

for FIXTURE in "${FIXTURES[@]}"; do
    CAF="$RECORDINGS/${FIXTURE}.caf"
    CSV="$RESULTS/${FIXTURE}.csv"
    if [ ! -f "$CAF" ]; then
        echo "WARN: $CAF not found, skipping."
        continue
    fi
    echo "  Processing $FIXTURE..."
    "$CLI" "$CAF" --output "$CSV" 2>"$RESULTS/${FIXTURE}.stderr" || {
        echo "  ERROR: CLI failed for $FIXTURE (exit $?). Continuing."
    }
done

# Real-world test (optional fallback)
RW_CAF="$RECORDINGS/real_world_test.caf"
if [ -f "$RW_CAF" ]; then
    echo "  Processing real_world_test..."
    "$CLI" "$RW_CAF" --output "$RESULTS/real_world_test.csv" \
        2>"$RESULTS/real_world_test.stderr" || {
        echo "  ERROR: CLI failed for real_world_test. Continuing."
    }
else
    echo "  WARN: real_world_test.caf not found — criterion 12 will use quiet_speech_pods."
fi

echo ""
echo "=== Phase 3: Evaluate clips ==="
for FIXTURE in "${FIXTURES[@]}" real_world_test; do
    CSV="$RESULTS/${FIXTURE}.csv"
    if [ ! -f "$CSV" ]; then
        continue
    fi
    "$EVAL" clip "$FIXTURE" --csv "$CSV" 2>/dev/null || true
done

echo ""
echo "=== Phase 4: Summarize ==="
"$EVAL" summarize \
    --results-dir "$RESULTS" \
    --bootstrap "$BOOTSTRAP"

echo ""
echo "=== Done ==="
VERDICT=$(python3 -c "import json; d=json.load(open('$RESULTS/summary.json')); print(d['verdict'])" 2>/dev/null || echo "UNKNOWN")
echo "Verdict: $VERDICT"
echo "See results/summary.json for details."
