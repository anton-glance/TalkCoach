#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RECORDINGS_DIR="$SCRIPT_DIR/recordings"
RESULTS_DIR="$SCRIPT_DIR/results"
MANIFEST="$RECORDINGS_DIR/manifest.json"

mkdir -p "$RESULTS_DIR"

CLI="swift run --package-path $SCRIPT_DIR LangDetectSpikeCLI"

OPTION_C_CSV="$RESULTS_DIR/option_c.csv"
$CLI evaluate-c --header 2>/dev/null > "$OPTION_C_CSV"

PAIRS=("en+ru" "en+ja" "en+es")

for pair in "${PAIRS[@]}"; do
    IFS='+' read -r lang1 lang2 <<< "$pair"

    for window in 3 5; do
        for clip_file in "$RECORDINGS_DIR"/${lang1}_*.caf "$RECORDINGS_DIR"/${lang2}_*.caf; do
            [ -f "$clip_file" ] || continue
            clipname="$(basename "$clip_file")"
            echo "  $clipname  pair=$pair  window=${window}s" >&2
            $CLI evaluate-c \
                --clip "$clip_file" \
                --pair "$pair" \
                --window "$window" \
                --manifest "$MANIFEST" 2>/dev/null >> "$OPTION_C_CSV" || echo "FAILED: $clipname pair=$pair window=$window" >&2
        done
    done
done

echo ""
echo "Done. $(wc -l < "$OPTION_C_CSV") lines in $OPTION_C_CSV"
