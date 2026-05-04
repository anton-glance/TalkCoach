#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPIKE_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$SPIKE_DIR/results"
MANIFEST="$SCRIPT_DIR/manifest.csv"

rm -f "$RESULTS_DIR/summary.csv"
mkdir -p "$RESULTS_DIR"

tail -n +2 "$MANIFEST" | while IFS=, read -r clip onset || [ -n "$clip" ]; do
    AUDIO="$SCRIPT_DIR/${clip}.caf"
    if [ ! -f "$AUDIO" ]; then
        echo "SKIP: $clip ($AUDIO not found)" >&2
        continue
    fi

    echo "Processing $clip..." >&2
    swift run --package-path "$SPIKE_DIR" ShoutingSpikeCLI \
        "$AUDIO" \
        --summary-csv "$RESULTS_DIR/summary.csv" \
        --time-series-csv "$RESULTS_DIR/timeseries_${clip}.csv"
done

if [ -f "$RESULTS_DIR/summary.csv" ]; then
    echo "" >&2
    echo "=== Summary ===" >&2
    cat "$RESULTS_DIR/summary.csv" >&2
else
    echo "No clips processed." >&2
    exit 1
fi
