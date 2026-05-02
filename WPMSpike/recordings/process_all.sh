#!/bin/bash
set -euo pipefail

THRESHOLD="${1:--40.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPIKE_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$SPIKE_DIR/results"

mkdir -p "$RESULTS_DIR"

CLIPS=(en_normal en_fast en_slow ru_normal ru_fast ru_slow)
COMBINED="$RESULTS_DIR/combined.csv"
HEADER_WRITTEN=false

for clip in "${CLIPS[@]}"; do
    AUDIO="$SCRIPT_DIR/${clip}.caf"
    if [ ! -f "$AUDIO" ]; then
        echo "Skipping $clip (no .caf file found)" >&2
        continue
    fi

    echo "Processing $clip..." >&2
    OUTPUT=$(swift run --package-path "$SPIKE_DIR" WPMSpikeCLI "$AUDIO" --vad-threshold "$THRESHOLD")

    if [ "$HEADER_WRITTEN" = false ]; then
        echo "$OUTPUT" > "$COMBINED"
        HEADER_WRITTEN=true
    else
        echo "$OUTPUT" | tail -n +2 >> "$COMBINED"
    fi
done

if [ "$HEADER_WRITTEN" = true ]; then
    echo "Results written to $COMBINED" >&2
else
    echo "No clips found in $SCRIPT_DIR" >&2
    exit 1
fi
