#!/usr/bin/env bash
# run_all.sh — Spike17.3 full pipeline runner.
# Usage: ./run_all.sh [k_length_ms]
# Default kLengthMs is read from results/LOCKED_K_LENGTH_MS if present,
# or 1000 if not yet locked (used during smoke gate phase).
set -e
cd "$(dirname "$0")"

MODEL="small"
MODEL_PATH="models/ggml-small.bin"
VAD_PATH="models/ggml-silero-v5.1.2.bin"

K_LENGTH_MS=${1:-$(cat results/LOCKED_K_LENGTH_MS 2>/dev/null || echo 1000)}

echo "=== Spike17.3 run_all.sh — kLengthMs=$K_LENGTH_MS ==="

CLI=".build/release/Spike17_3CLI"

# 11 fixtures: 10 speech/noise + real_world_test
FIXTURES=(
    "alternating_pods:pods"
    "alternating_mac:mac"
    "quiet_speech_pods:pods"
    "quiet_speech_mac:mac"
    "cafe_noise_pods:pods"
    "cafe_noise_mac:mac"
    "silence_only_pods:pods"
    "silence_only_mac:mac"
    "distractors_pods:pods"
    "distractors_mac:mac"
    "real_world_test:pods"  # real_world_test uses pods threshold (unknown mic; pods is conservative)
)

for ENTRY in "${FIXTURES[@]}"; do
    FIXTURE="${ENTRY%%:*}"
    MIC="${ENTRY##*:}"
    echo "--- $FIXTURE (mic=$MIC) ---"
    "$CLI" run \
        --recording "recordings/${FIXTURE}.caf" \
        --model "$MODEL_PATH" \
        --vad "$VAD_PATH" \
        --k-length-ms "$K_LENGTH_MS" \
        --mic-profile "$MIC" \
        --output "results/${FIXTURE}_${MODEL}.csv"
done

echo "=== All fixtures complete ==="
