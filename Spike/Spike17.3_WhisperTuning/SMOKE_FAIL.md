# SMOKE-GATE FAIL — Spike #17.3

## Verdict

SMOKE-GATE FAIL. All three kLengthMs values tested failed the C4 ≤ 200ms budget.
Per the NO-SKIPPING rule (Session 030 lock): STOP. No further kLengthMs tuning.

## Measured C4 per kLengthMs (bootstrap warm pass, whisper-small, M3 Metal)

    kLengthMs=1000   C4 pods=453ms   C4 mac=1322ms   Budget=200ms   FAIL
    kLengthMs=800    C4 pods=304ms   C4 mac=280ms    Budget=200ms   FAIL
    kLengthMs=600    C4 pods=335ms   C4 mac=308ms    Budget=200ms   FAIL

## Root Cause: Architectural — whisper always pads to 30s mel

The tuning hypothesis (kLengthMs reduction → C4 improvement proportional to window size)
was architecturally incorrect. whisper.cpp's `whisper_pcm_to_mel` always computes a
fixed-size mel spectrogram covering 30 × 16000 = 480,000 samples (30 seconds), zero-padding
shorter input audio to fill the context. The transformer encoder therefore always runs on
1500 mel frames regardless of input audio length. The C4 floor for whisper-small on Metal M3
is ~300–450ms for all kLengthMs values tested.

Evidence: C4 values at kLengthMs=3000 (#17.2), 1000, 800, and 600 are all within the same
~300–450ms range, with no monotonic improvement as kLengthMs decreases. The 800ms result
(304ms) shows marginally lower C4 than 600ms (335ms), confirming the noise floor — variance
dominates over any real kLengthMs scaling effect.

## What DID improve

Fixes 2-5 are valid and productive regardless of the smoke gate outcome:
- Fix 2 (threshold-aware VAD): implemented and building correctly
- Fix 3 (special token filter): implemented
- Fix 4 (audioSamplePositionMs in TokenEvent): implemented, C8 eval fixed
- Fix 5 (startup fixture verify): implemented, all 11 fixtures confirmed

## Escalation path (per #17.2 REPORT.md §Escalation)

Option A: whisper-tiny with 1s ring buffer.
  Expected C4: ~40–75ms (whisper-tiny is 4× smaller encoder; ~4× faster).
  Risk: reduced filler detection accuracy on short clips.
  Next spike: Spike #17.4-whisper-tiny.

Option B: Sherpa-ONNX with moonshine-tiny.
  Designed for streaming ASR, not 30s context architecture.
  Latency target: <100ms per chunk on CPU. No Metal dependency.
  Next spike: Spike #17.4-moonshine.

Option C: Apple SpeechAnalyzer (English only).
  Already validated in earlier spikes. No latency issue.
  Limitation: English-only; does not support the Russian/multi-language architecture.

## Recommendation

Proceed to Spike #17.4 with Option A (whisper-tiny). It reuses 100% of the #17.3
infrastructure; only the model file and --model flag change. If whisper-tiny fails
C9 accuracy criterion, pivot to Option B (moonshine-tiny). See REPORT.md §Recommendation.
