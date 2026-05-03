#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RECORDINGS_DIR="$SCRIPT_DIR/recordings"
RESULTS_DIR="$SCRIPT_DIR/results"
MANIFEST="$RECORDINGS_DIR/manifest.json"

mkdir -p "$RESULTS_DIR"

if [ ! -f "$MANIFEST" ]; then
    echo "Error: manifest.json not found at $MANIFEST" >&2
    echo "Copy manifest.example.json to recordings/manifest.json and fill in your clips." >&2
    exit 1
fi

CLI="swift run --package-path $SCRIPT_DIR LangDetectSpikeCLI"

echo "=== Preflight ==="
$CLI preflight --manifest "$MANIFEST"
echo ""

PAIRS=("en+ru" "en+ja" "en+es")

# ---------------------------------------------------------------------------
# Option B: wrong-guess + correct-guess (48 evaluations total)
# ---------------------------------------------------------------------------
echo "=== Option B evaluations ==="
OPTION_B_CSV="$RESULTS_DIR/option_b.csv"
$CLI evaluate-b --header > "$OPTION_B_CSV"

for pair in "${PAIRS[@]}"; do
    IFS='+' read -r lang1 lang2 <<< "$pair"

    # Wrong-guess: initialize with the opposite language
    for clip_file in "$RECORDINGS_DIR"/${lang1}_*.caf; do
        [ -f "$clip_file" ] || continue
        $CLI evaluate-b \
            --clip "$clip_file" \
            --pair "$pair" \
            --guess-mode wrong \
            --manifest "$MANIFEST" >> "$OPTION_B_CSV" || true
    done
    for clip_file in "$RECORDINGS_DIR"/${lang2}_*.caf; do
        [ -f "$clip_file" ] || continue
        $CLI evaluate-b \
            --clip "$clip_file" \
            --pair "$pair" \
            --guess-mode wrong \
            --manifest "$MANIFEST" >> "$OPTION_B_CSV" || true
    done

    # Correct-guess: initialize with the correct language
    for clip_file in "$RECORDINGS_DIR"/${lang1}_*.caf; do
        [ -f "$clip_file" ] || continue
        $CLI evaluate-b \
            --clip "$clip_file" \
            --pair "$pair" \
            --guess-mode correct \
            --manifest "$MANIFEST" >> "$OPTION_B_CSV" || true
    done
    for clip_file in "$RECORDINGS_DIR"/${lang2}_*.caf; do
        [ -f "$clip_file" ] || continue
        $CLI evaluate-b \
            --clip "$clip_file" \
            --pair "$pair" \
            --guess-mode correct \
            --manifest "$MANIFEST" >> "$OPTION_B_CSV" || true
    done
done

echo "Option B results: $OPTION_B_CSV"
echo ""

# ---------------------------------------------------------------------------
# Option C: 3s + 5s windows (48 evaluations total)
# ---------------------------------------------------------------------------
echo "=== Option C evaluations ==="
OPTION_C_CSV="$RESULTS_DIR/option_c.csv"
$CLI evaluate-c --header > "$OPTION_C_CSV"

for pair in "${PAIRS[@]}"; do
    IFS='+' read -r lang1 lang2 <<< "$pair"

    for window in 3 5; do
        for clip_file in "$RECORDINGS_DIR"/${lang1}_*.caf "$RECORDINGS_DIR"/${lang2}_*.caf; do
            [ -f "$clip_file" ] || continue
            $CLI evaluate-c \
                --clip "$clip_file" \
                --pair "$pair" \
                --window "$window" \
                --manifest "$MANIFEST" >> "$OPTION_C_CSV" || true
        done
    done
done

echo "Option C results: $OPTION_C_CSV"
echo ""

# ---------------------------------------------------------------------------
# Word-count analysis (runs on Option B CSV)
# ---------------------------------------------------------------------------
echo "=== Word-count analysis ==="
WORDCOUNT_TXT="$RESULTS_DIR/wordcount_analysis.txt"
$CLI analyze-wordcount --csv "$OPTION_B_CSV" > "$WORDCOUNT_TXT"
cat "$WORDCOUNT_TXT"
echo ""
echo "Word-count analysis: $WORDCOUNT_TXT"

echo ""
echo "Done. All results in $RESULTS_DIR/"
