#!/bin/bash
set -e

SPIKE_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI="$SPIKE_DIR/.build/debug/Spike16CLI"
EVAL="$SPIKE_DIR/.build/debug/Spike16Eval"

echo "Building..." >&2
swift build --package-path "$SPIKE_DIR" --product Spike16CLI 2>&1
swift build --package-path "$SPIKE_DIR" --product Spike16Eval 2>&1

mkdir -p "$SPIKE_DIR/results"

CLIPS=(
    alternating_pods
    alternating_mac
    quiet_speech_pods
    quiet_speech_mac
    cafe_noise_pods
    cafe_noise_mac
    silence_only_pods
    silence_only_mac
    distractors_pods
    distractors_mac
)

echo "Processing clips..." >&2
for CLIP in "${CLIPS[@]}"; do
    echo "  $CLIP..." >&2
    "$CLI" "$SPIKE_DIR/recordings/${CLIP}.caf" \
        > "$SPIKE_DIR/results/${CLIP}.csv" \
        2>"$SPIKE_DIR/results/${CLIP}.stderr"
    "$EVAL" \
        --clip "$CLIP" \
        --csv "$SPIKE_DIR/results/${CLIP}.csv" \
        --manifest "$SPIKE_DIR/recordings/manifest.csv" \
        --output "$SPIKE_DIR/results/${CLIP}.json" \
        2>&1
done

echo "Summarizing..." >&2
"$EVAL" --summarize --results-dir "$SPIKE_DIR/results" 2>&1

VERDICT=$(python3 -c "import json; d=json.load(open('$SPIKE_DIR/results/summary.json')); print(d['verdict'])")
echo "run_all.sh complete. Verdict: $VERDICT" >&2

# Parameter sweep (only when --with-sweep flag is provided)
if [[ "$1" == "--with-sweep" ]]; then
    echo "Running parameter sweep..." >&2
    SWEEP_CSV="$SPIKE_DIR/results/parameter_sweep.csv"
    echo "voice_on_count,voice_off_count,threshold_margin_db,onset_median_ms,onset_p95_ms,end_median_ms,end_p95_ms,silence_fp_max_ms,speech_fn_max_pct,distractor_max_pct,overall_verdict" > "$SWEEP_CSV"

    for VON in 2 3 5; do
    for VOFF in 20 30 45; do
    for MARGIN in 10.0 15.0 20.0; do
        SWEEP_DIR="$SPIKE_DIR/results/sweep_${VON}_${VOFF}_${MARGIN}"
        mkdir -p "$SWEEP_DIR"
        for CLIP in "${CLIPS[@]}"; do
            "$CLI" "$SPIKE_DIR/recordings/${CLIP}.caf" \
                --voice-on-count "$VON" \
                --voice-off-count "$VOFF" \
                --threshold-margin "$MARGIN" \
                > "$SWEEP_DIR/${CLIP}.csv" 2>/dev/null
            "$EVAL" \
                --clip "$CLIP" \
                --csv "$SWEEP_DIR/${CLIP}.csv" \
                --manifest "$SPIKE_DIR/recordings/manifest.csv" \
                --output "$SWEEP_DIR/${CLIP}.json" \
                2>/dev/null
        done
        "$EVAL" --summarize --results-dir "$SWEEP_DIR" 2>/dev/null
        python3 - <<EOF >> "$SWEEP_CSV"
import json
d=json.load(open('$SWEEP_DIR/summary.json'))
a=d['aggregate']
row=[
    '$VON','$VOFF','$MARGIN',
    str(a['onset_latency_median_ms']),
    str(a['onset_latency_p95_ms']),
    str(a['end_latency_median_ms']),
    str(a['end_latency_p95_ms']),
    str(max(a['silence_only_pods_fp_ms'], a['silence_only_mac_fp_ms'])),
    str(round(a['speech_fn_max_pct'],2)),
    str(round(a['distractor_max_incorrect_pct'],2)),
    d['verdict'],
]
print(','.join(row))
EOF
        echo "    sweep ${VON}/${VOFF}/${MARGIN} done" >&2
    done
    done
    done
    echo "Sweep complete: $SWEEP_CSV" >&2
fi
