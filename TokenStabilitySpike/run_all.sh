#!/bin/bash
# Spike #8 — Token-arrival robustness across mics and environments
# Runs all recordings through the stability harness.
# Outputs: results/stability.csv (main), results/*_tokens.csv (per-clip tokens)

set -euo pipefail
cd "$(dirname "$0")"

RESULTS_DIR="results"
CSV="$RESULTS_DIR/stability.csv"
TOKENS_DIR="$RESULTS_DIR"

mkdir -p "$RESULTS_DIR"

# Print CSV header
swift run TokenStabilitySpikeCLI --header 2>/dev/null > "$CSV"

# Step 1: Reference clip from WPMSpike (sanity check — should match S6 result)
REFERENCE="../WPMSpike/recordings/en_normal.caf"
if [ -f "$REFERENCE" ]; then
    echo "Processing reference: en_normal (WPMSpike)..." >&2
    swift run TokenStabilitySpikeCLI "$REFERENCE" \
        --tokens-dir "$TOKENS_DIR" 2>/dev/null >> "$CSV"
else
    echo "WARNING: WPMSpike reference clip not found at $REFERENCE" >&2
    echo "Skipping reference sanity check." >&2
fi

# Step 2: Stability test clips (4 conditions)
CLIPS=(
    "recordings/mbp_quiet.caf"
    "recordings/mbp_noisy.caf"
    "recordings/airpods_quiet.caf"
    "recordings/airpods_noisy.caf"
)

for clip in "${CLIPS[@]}"; do
    if [ -f "$clip" ]; then
        name=$(basename "$clip" .caf)
        echo "Processing: $name..." >&2
        swift run TokenStabilitySpikeCLI "$clip" \
            --tokens-dir "$TOKENS_DIR" 2>/dev/null >> "$CSV"
    else
        echo "SKIP: $clip not found (record it first)" >&2
    fi
done

echo "" >&2
echo "=== Results ===" >&2
cat "$CSV" >&2
echo "" >&2
echo "Wrote: $CSV" >&2
