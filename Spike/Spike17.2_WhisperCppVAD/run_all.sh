#!/bin/bash
# Spike #17.2 — whisper.cpp v1.8.4 + Silero VAD — Four-gate evaluation script
# Run from Spike17.2_WhisperCppVAD/ directory.
set -euo pipefail

SPIKE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SPIKE_DIR"

MODELS_DIR="$SPIKE_DIR/models"
RESULTS_DIR="$SPIKE_DIR/results"
BUILD_DIR="$SPIKE_DIR/build"
WHISPER_DIR="$SPIKE_DIR/whisper.cpp"
NCPU=$(sysctl -n hw.logicalcpu)

WHISPER_SMALL="$MODELS_DIR/ggml-small.bin"
WHISPER_MEDIUM="$MODELS_DIR/ggml-medium.bin"
VAD_MODEL="$MODELS_DIR/ggml-silero-v5.1.2.bin"

FIXTURES=(
    "alternating_pods"
    "alternating_mac"
    "quiet_speech_pods"
    "quiet_speech_mac"
    "cafe_noise_pods"
    "cafe_noise_mac"
    "silence_only_pods"
    "silence_only_mac"
    "distractors_pods"
    "distractors_mac"
)

mkdir -p "$RESULTS_DIR" "$MODELS_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
fail() { echo "[FAIL] $*" >&2; exit 1; }

# ============================================================
# BUILD-GATE
# ============================================================
log "=== BUILD-GATE ==="

if [ ! -f "$BUILD_DIR/libwhisper.a" ]; then
    log "cmake configure..."
    cmake -B "$BUILD_DIR" -S "$WHISPER_DIR" \
        -DGGML_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_EXAMPLES=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        2>&1 || {
            log "cmake configure failed — writing BUILD_FAIL.md"
            cat > BUILD_FAIL.md <<'EOF'
# BUILD-GATE FAIL

cmake configure failed. See run_all.sh output.
Likely cause: missing Xcode command line tools or CMake not installed.
Fix: xcode-select --install && brew install cmake
EOF
            exit 1
        }

    log "cmake build (using $NCPU threads)..."
    cmake --build "$BUILD_DIR" --target whisper -j"$NCPU" 2>&1 || {
        log "cmake build failed — writing BUILD_FAIL.md"
        cat > BUILD_FAIL.md <<'EOF'
# BUILD-GATE FAIL

cmake build of libwhisper.a failed. See run_all.sh output.
EOF
        exit 1
    }
fi

if [ ! -f "$BUILD_DIR/libwhisper.a" ]; then
    cat > BUILD_FAIL.md <<'EOF'
# BUILD-GATE FAIL

cmake succeeded but libwhisper.a not found at expected path.
Expected: build/libwhisper.a
EOF
    fail "libwhisper.a not produced by cmake"
fi

log "swift build..."
swift build --product Spike17_2CLI --configuration release 2>&1 || {
    log "swift build failed — writing BUILD_FAIL.md"
    cat > BUILD_FAIL.md <<'EOF'
# BUILD-GATE FAIL

`swift build --product Spike17_2CLI` failed.
This may indicate a Swift-C bridging issue or linker error.
See run_all.sh output for details.
EOF
    exit 1
}

swift build --product Spike17_2Eval --configuration release 2>&1 || {
    log "swift build Spike17_2Eval failed — writing BUILD_FAIL.md"
    cat > BUILD_FAIL.md << 'EOF'
# BUILD-GATE FAIL

`swift build --product Spike17_2Eval` failed.
EOF
    exit 1
}

CLI=".build/release/Spike17_2CLI"
EVAL=".build/release/Spike17_2Eval"

# Verify Metal in system info via a bootstrap hello-world call (needs models)
# We skip Metal verification here; it will be evident in bootstrap output.
log "BUILD-GATE PASSED"

# ============================================================
# SMOKE-GATE
# ============================================================
log "=== SMOKE-GATE ==="

# Download models if absent
if [ ! -f "$WHISPER_SMALL" ]; then
    log "Downloading ggml-small.bin (~244MB)..."
    "$CLI" download --model small || fail "model download failed"
fi

if [ ! -f "$VAD_MODEL" ]; then
    log "Downloading Silero VAD model (~2MB)..."
    "$CLI" download --vad || fail "VAD model download failed"
fi

log "Running bootstrap on quiet_speech_pods.caf..."
"$CLI" bootstrap \
    --model "$WHISPER_SMALL" \
    --vad "$VAD_MODEL" \
    --output "$RESULTS_DIR/bootstrap_small.json" || {
    cat > SMOKE_FAIL.md <<'EOF'
# SMOKE-GATE FAIL

bootstrap command failed. See run_all.sh output.
EOF
    fail "bootstrap failed"
}

log "Transcribing quiet_speech_pods.caf for smoke check..."
"$CLI" run \
    --recording "recordings/quiet_speech_pods.caf" \
    --model "$WHISPER_SMALL" \
    --vad "$VAD_MODEL" \
    --output "$RESULTS_DIR/smoke_small.csv" || {
    cat > SMOKE_FAIL.md <<'EOF'
# SMOKE-GATE FAIL

CLI run command failed on quiet_speech_pods.caf.
EOF
    fail "CLI run failed"
}

# Verify at least 1 non-empty text row and 1 is_confirmed row
NONEMPTY=$(tail -n +2 "$RESULTS_DIR/smoke_small.csv" | awk -F',' '$4 != ""' | wc -l | tr -d ' ')
CONFIRMED=$(tail -n +2 "$RESULTS_DIR/smoke_small.csv" | awk -F',' '$5 == "1"' | wc -l | tr -d ' ')

if [ "$NONEMPTY" -lt 1 ]; then
    cat > SMOKE_FAIL.md <<'EOF'
# SMOKE-GATE FAIL

smoke_small.csv contains no non-empty text rows.
Possible causes: VAD threshold too high, Metal not initializing, model not producing output.
Check: quiet_speech_pods.caf is a valid speech recording.
EOF
    fail "smoke CSV has no text"
fi

if [ "$CONFIRMED" -lt 1 ]; then
    cat > SMOKE_FAIL.md <<'EOF'
# SMOKE-GATE FAIL

smoke_small.csv contains no is_confirmed=1 rows.
VAD never detected an end-of-speech boundary.
Check: Silero VAD threshold (default 0.5) may be too high for this recording.
EOF
    fail "smoke CSV has no confirmed events"
fi

# Write smoke baseline JSON for C9 gating
log "Writing SMOKE_BASELINE.json..."
python3 tools/write_smoke_baseline.py || log "WARNING: could not write smoke baseline (C9 will use fallback threshold)"
# Copy to root results dir for eval
cp "$RESULTS_DIR/SMOKE_BASELINE.json" . 2>/dev/null || true

log "SMOKE-GATE PASSED (non-empty rows: $NONEMPTY, confirmed: $CONFIRMED)"

# ============================================================
# EARLY-GATE (whisper-small, C4/C5/C8 only, all 10 fixtures)
# ============================================================
log "=== EARLY-GATE (whisper-small, 10 fixtures) ==="

for FIXTURE in "${FIXTURES[@]}"; do
    log "  Processing $FIXTURE..."
    "$CLI" run \
        --recording "recordings/${FIXTURE}.caf" \
        --model "$WHISPER_SMALL" \
        --vad "$VAD_MODEL" \
        --output "$RESULTS_DIR/${FIXTURE}_small.csv" || {
        log "WARNING: CLI failed on $FIXTURE — continuing with next fixture"
    }
done

# Score early gate: only C4, C5, C8
"$EVAL" \
    --model small \
    --criteria C4,C5,C8 \
    --manifest recordings/manifest.csv \
    --results-dir "$RESULTS_DIR" \
    --smoke-baseline results/SMOKE_BASELINE.json \
    --output "$RESULTS_DIR/EARLY_summary.json" || true

# NO-SKIPPING check (Session 030 lock)
python3 tools/check_no_skipping.py "$RESULTS_DIR/EARLY_summary.json" || {
    log "NO-SKIPPING triggered — EARLY-GATE FAIL (10x budget miss)"
    cat > EARLY_FAIL.md <<EOF
# EARLY-GATE FAIL — NO-SKIPPING

C4 first-token latency exceeded 2000ms (10× budget miss).
This indicates an architectural incompatibility, not a tuning issue.
Root cause will be documented in REPORT.md.

See: results/EARLY_summary.json for exact measurement.
See: results/bootstrap_small.json for C4 and Metal info.
EOF
    # Still run GATE2 analysis for documentation — but exit with FAIL
    log "Writing REPORT.md with NO-SKIPPING verdict..."
    # Fall through to REPORT.md generation below
    GATE_VERDICT="EARLY_FAIL_NO_SKIPPING"
    export GATE_VERDICT
}

# Check if C4/C5/C8 pass (even without NO-SKIPPING)
EARLY_VERDICT=$(python3 -c "
import json, sys
with open('$RESULTS_DIR/EARLY_summary.json') as f: d=json.load(f)
fails=[c for c in d['criteria'] if c['disposition']=='FAIL']
print('FAIL' if fails else 'PASS')
" 2>/dev/null || echo "UNKNOWN")

if [ "$EARLY_VERDICT" != "PASS" ]; then
    log "EARLY-GATE FAIL on C4/C5/C8 — writing EARLY_FAIL.md"
    python3 -c "
import json
with open('$RESULTS_DIR/EARLY_summary.json') as f: d=json.load(f)
fails=[c for c in d['criteria'] if c['disposition']=='FAIL']
print('Failed criteria:')
for c in fails: print(f'  {c[\"id\"]}: {c[\"measured\"]} (budget: {c[\"budget\"]})')
" 2>/dev/null || true
    cat > EARLY_FAIL.md <<'EOF'
# EARLY-GATE FAIL

One or more of C4/C5/C8 failed with whisper-small.
See results/EARLY_summary.json for details.
REPORT.md will document root cause and recommendation.
EOF
    log "NOTE: Per plan, EARLY-GATE FAIL exits before GATE2. Writing REPORT.md then exiting."
    GATE_VERDICT="EARLY_FAIL"
else
    log "EARLY-GATE PASSED (C4/C5/C8 green) — proceeding to GATE2"
    GATE_VERDICT="EARLY_PASS"
fi

# ============================================================
# GATE 2 (only runs if EARLY-GATE PASSES)
# ============================================================
if [ "${GATE_VERDICT:-}" = "EARLY_PASS" ]; then
    log "=== GATE 2 (whisper-small, all 12 criteria) ==="

    "$EVAL" \
        --model small \
        --criteria all \
        --manifest recordings/manifest.csv \
        --results-dir "$RESULTS_DIR" \
        --smoke-baseline results/SMOKE_BASELINE.json \
        --output "$RESULTS_DIR/GATE2_summary_small.json" || true

    GATE2_VERDICT=$(python3 -c "
import json
with open('$RESULTS_DIR/GATE2_summary_small.json') as f: d=json.load(f)
fails=[c for c in d['criteria'] if c['disposition']=='FAIL']
acc_fails=[c['id'] for c in fails if c['id'] in ['C6','C10','C12']]
print('ACCURACY_FAIL' if acc_fails else ('FAIL' if fails else 'PASS'))
" 2>/dev/null || echo "UNKNOWN")

    if [ "$GATE2_VERDICT" = "ACCURACY_FAIL" ]; then
        log "GATE2: small failed accuracy (C6/C10/C12) — trying whisper-medium"
        if [ ! -f "$WHISPER_MEDIUM" ]; then
            log "Downloading ggml-medium.bin (~769MB)..."
            "$CLI" download --model medium || log "WARNING: medium download failed"
        fi

        if [ -f "$WHISPER_MEDIUM" ]; then
            for FIXTURE in "${FIXTURES[@]}"; do
                log "  [medium] Processing $FIXTURE..."
                "$CLI" run \
                    --recording "recordings/${FIXTURE}.caf" \
                    --model "$WHISPER_MEDIUM" \
                    --vad "$VAD_MODEL" \
                    --output "$RESULTS_DIR/${FIXTURE}_medium.csv" || true
            done

            "$CLI" bootstrap \
                --model "$WHISPER_MEDIUM" \
                --vad "$VAD_MODEL" \
                --output "$RESULTS_DIR/bootstrap_medium.json" || true

            "$EVAL" \
                --model medium \
                --criteria C6,C10,C12 \
                --manifest recordings/manifest.csv \
                --results-dir "$RESULTS_DIR" \
                --smoke-baseline results/SMOKE_BASELINE.json \
                --output "$RESULTS_DIR/GATE2_summary_medium.json" || true

            MEDIUM_VERDICT=$(python3 -c "
import json
with open('$RESULTS_DIR/GATE2_summary_medium.json') as f: d=json.load(f)
fails=[c for c in d['criteria'] if c['disposition']=='FAIL']
print('NEEDS_TUNING' if not fails else 'GATE2_FAIL')
" 2>/dev/null || echo "GATE2_FAIL")
            GATE_VERDICT="$MEDIUM_VERDICT"
        else
            GATE_VERDICT="GATE2_FAIL_NO_MEDIUM"
        fi
    elif [ "$GATE2_VERDICT" = "PASS" ]; then
        GATE_VERDICT="GATE2_PASS"
        cat > GATE2_PASS.md <<'EOF'
# GATE 2 PASS

All 12 criteria passed with whisper-small.
See results/GATE2_summary_small.json for full scorecard.
EOF
    else
        GATE_VERDICT="GATE2_FAIL"
        cat > GATE2_FAIL.md <<'EOF'
# GATE 2 FAIL

One or more criteria failed with whisper-small.
See results/GATE2_summary_small.json for details.
EOF
    fi

    # 3-way comparison
    python3 tools/compare_to_17_x.py 2>/dev/null || log "WARNING: comparison tool failed"
    log "GATE2 verdict: $GATE_VERDICT"
fi

log "=== Final verdict: ${GATE_VERDICT:-UNKNOWN} ==="
log "Next step: write REPORT.md (Phase 3)"
