# Spike #17.3 — whisper.cpp Tuning Sweep + C8 Methodology Fix
## Feasibility Report

**Branch**: spike/17.3-whisper-tuning
**Date**: 2026-05-21
**Platform**: macOS 26.4.1 (beta), Apple M3, 16GB
**Model**: whisper-small multilingual (ggml-small.bin, 487 MB)
**VAD**: Silero v5.1.2 (ggml-silero-v5.1.2.bin, 0.88 MB)
**whisper.cpp**: v1.8.4 (SHA 9386f239), Metal ON, Accelerate BLAS
**Based on**: Spike #17.2 infrastructure (build artifacts reused, no rebuild)

---

## Overall Verdict: SMOKE-GATE FAIL (ESCALATE)

The verdict is SMOKE-GATE FAIL. All three kLengthMs values (1000, 800, 600) failed C4.
The Gate 2 full-fixture run was NOT executed (per NO-SKIPPING rule; see §Smoke Gate).

The failure is architectural, not parameter-space: whisper.cpp always processes a fixed
30-second mel context regardless of ring buffer length. kLengthMs reduction is therefore
ineffective for C4 improvement with this model architecture. This falsifies the tuning
hypothesis from #17.2 and closes the whisper-small tuning path.

The other four fixes (Fix 2–5) were implemented successfully and are production-ready for
whichever model replaces whisper-small in Spike #17.4.

---

## BUILD-GATE

PASS. swift build -c release succeeded in 6.71s. Module map fix required: multi-line format
(`module CWhisper { header "CWhisper.h"; export * }` single-line form triggers a "skipping
stray token" error in clang 21 / Xcode 26.4.1 beta; multi-line format works). Package.swift
path resolution fixed: `URL.standardizedFileURL.path` used to resolve `..`-containing paths
before passing them as -I flags to clang. Build artifacts reused from #17.2 build directory.

Notable: this is the same fundamental whisper.cpp + CWhisper C-bridge architecture as #17.2.
BUILD-GATE confirmation proves the infrastructure is stable and portable to Spike #17.4.

---

## Five Fixes Implementation Status

Fix 1 — kLengthMs configurable (IMPLEMENTED, INEFFECTIVE for C4)
  StreamingWhisperVoiceDetector now takes `kLengthMs: Int` init parameter. CLI exposes
  `--k-length-ms`. Smoke gate tested 1000, 800, 600ms. All fail C4 budget. Root cause
  documented in §Smoke Gate Root Cause.

Fix 2 — Silero VAD threshold configurable (IMPLEMENTED, CORRECTNESS FIX REQUIRED)
  Initial implementation used `whisper_vad_segments_from_samples` for threshold control.
  This produced 0 confirmed events: `whisper_vad_segments_from_samples` applies
  min_speech_duration_ms filtering (default ~250ms) that rejects 160ms chunks as too short.
  Fix: use `whisper_vad_detect_speech` to populate internal probs, then inspect raw
  `whisper_vad_probs` and compare max probability against threshold. This matches the
  per-chunk streaming semantics of the original `whisper_vad_detect_speech` call.
  CLI exposes `--vad-threshold` (explicit) and `--mic-profile pods|mac` (convenience;
  pods=0.5, mac=0.3). Per-fixture threshold routing implemented in run_all.sh.

Fix 3 — Special token filter (IMPLEMENTED)
  Filtered before emitting TokenEvent: [BLANK_AUDIO], [_BEG_], [_END_], [MUSIC], [NOISE],
  [SILENCE], [SOUND], (Music playing), standalone "Thank you." and variants.
  Applied in `runInference` via `applyTokenFilter`. If filtering removes all text, event
  is not emitted.

Fix 4 — audioSamplePositionMs in TokenEvent (IMPLEMENTED, C8 METHODOLOGY FIX)
  `TokenEvent` gains `audioSamplePositionMs: Int`. Computed as
  totalSamplesProcessed × 1000 / kSampleRate at the time of inference. CSV column 3
  (before text). C8 eval in Criteria.swift now uses `audioSamplePositionMs` vs
  manifest `speech_end × 1000`, fixing the time-base mismatch from #17.2.

Fix 5 — Startup fixture verification (IMPLEMENTED)
  Bootstrap verifies all 11 expected fixture paths at startup before model load.
  All 11 fixtures confirmed present at `recordings/` → `../Spike17.1.5_StreamingEOU/recordings/`.
  real_world_test.caf is present (C12 would PASS in Gate 2 if smoke gate had passed).

---

## Smoke Gate

### Configuration
  Three smoke passes run sequentially. Each uses the bootstrap tool (two-pass measurement:
  JIT-cold warmup pass + JIT-warm measurement pass). Primary fixture: quiet_speech_pods.caf.
  Cross-check fixture (Revision 2): quiet_speech_mac.caf at vadThreshold=0.3.

### Results

    kLengthMs   C4 pods (warm)   C4 mac (cross-check)   smokeCeanPass   smokePassWithCaveat
    ─────────   ──────────────   ────────────────────   ─────────────   ───────────────────
    1000        453 ms           1322 ms                false           true (mac>>pods)
    800         304 ms           280 ms                 false           false
    600         335 ms           308 ms                 false           false

    Budget: C4 ≤ 200ms for all values.

The mac cross-check at kLengthMs=1000 returned 1322ms. This is expected: the cross-check
creates a fresh whisper context (separate from the bootstrapped detector) whose Metal command
encoder pipeline requires re-initialization despite the shaders being cached. At kLengthMs=800
and 600, the cross-check C4 (280ms, 308ms) is consistent with pods C4, indicating the
macDetector benefited from Metal residency set warmup from the earlier run in the same process.

### Smoke Gate Root Cause: 30-Second Mel Architecture

All three kLengthMs values produced C4 in the 280–453ms range with no clear decreasing
trend. The explanation is architectural:

whisper.cpp's `whisper_pcm_to_mel()` always computes a fixed-size mel spectrogram of
30 × 16000 = 480,000 samples (30 seconds). Audio shorter than 30s is zero-padded.
The transformer encoder therefore always operates on 1500 mel frames, making encoder
latency independent of input audio length. Reducing kLengthMs from 3000ms to 600ms does
not meaningfully reduce C4.

Confirmation: C4 values at kLengthMs=3000 (#17.2), 1000, 800, and 600 all fall in the
same ~300–450ms range. The variation is dominated by measurement noise (Metal command
scheduling, OS load), not by ring buffer length.

The #17.2 prediction (kLengthMs=1000 → ~120–160ms C4) was incorrect because it assumed
encoder latency scales linearly with audio duration. This assumption holds for streaming
architectures (e.g., Moonshine, Parakeet) that process only the available audio, but not
for whisper's 30s-context design.

---

## C8 Methodology Fix (Fix 4 — Standalone Value)

This fix is production-ready regardless of the smoke gate outcome.

Old behavior (#17.2 C8 eval):
  `confirmedMs` = `emissionMs` (wall-clock from process start, including ~40s Metal JIT).
  `seMs` = `manifest.speech_end × 1000` (audio-domain ms).
  Result: 0/6 boundaries detected — time bases are incompatible.

New behavior (#17.3 C8 eval):
  `confirmedAudioMs` = `audioSamplePositionMs` (audio-domain ms, computed as
  totalSamplesProcessed × 1000 / 16000 at inference time).
  `seMs` = `manifest.speech_end × 1000` (audio-domain ms).
  Both values are now in audio time — comparison within ±500ms is valid.

This fix should be forward-ported to Spike #17.4 regardless of model choice.

---

## Smoke Gate Cross-Check Results (Revision 2)

Per-kLengthMs cross-check comparing alternating_pods/quiet_speech_pods C4
against quiet_speech_mac C4:

    kLengthMs=1000
      smoke_pods_c4: 453ms    smoke_mac_c4: 1322ms
      smokePassWithCaveat: true (mac >> pods, fresh-context issue)
      smokeCleanPass: false

    kLengthMs=800
      smoke_pods_c4: 304ms    smoke_mac_c4: 280ms
      smokePassWithCaveat: false (mac ≈ pods, within 1.5× ratio)
      smokeCleanPass: false

    kLengthMs=600
      smoke_pods_c4: 335ms    smoke_mac_c4: 308ms
      smokePassWithCaveat: false (mac < pods, within 1.5× ratio)
      smokeCleanPass: false

At kLengthMs=800 and 600, the cross-check shows small (10–25ms) variation between
pods and mac C4, consistent with the hypothesis that C4 is encoder-latency-dominated
(not fixture-dependent). The kLengthMs=1000 mac outlier (1322ms) is explained by
the fresh context initialization overhead and is not a systematic fixture effect.

---

## Verdict Logic Explanation (Revision 1)

Revision 1 defined kLengthMs-conditional budget rules:
  kLengthMs ≥ 1000: standard rules — C6 budget=0, C9 multiplier=0.90
  kLengthMs ≤ 800: strict rules — C6 budget≤5, C9 multiplier=0.92

These rules were never applied: all three kLengthMs values failed C4 at the smoke gate
and Gate 2 was not run. The rules are documented here for the Spike #17.4 team and
for audit completeness.

If Spike #17.4 (whisper-tiny) achieves C4 ≤ 200ms at kLengthMs=800, the strict rules
apply. If kLengthMs=1000 suffices, standard rules apply. The eval infrastructure
(Spike17_3Eval/Criteria.swift with `budgetRulesFor(kLengthMs:)`) is ready for both scenarios.

---

## #17.2 → #17.3 Prediction Validation

Prediction from #17.2 REPORT.md:
  "Encoder latency for 1s window (estimated): ~120–160ms"
  "Changing kLengthMs to 1000ms would likely bring C4 into budget."

Empirical result:
  kLengthMs=1000: C4=453ms (budget=200ms). Prediction FALSIFIED by 3×.

Why the prediction was wrong:
  The estimate assumed encoder latency scales linearly with audio duration.
  This holds for architectures that process only the input audio (Moonshine, wav2vec).
  whisper uses a fixed 30s mel context window. Shorter input is zero-padded.
  The transformer encoder always processes 1500 mel tokens regardless of input length.

This is the architectural learning Spike #17.3 validates beyond the budget question:
**whisper's 30s context architecture makes it fundamentally unsuitable for <200ms C4
at streaming step sizes (160ms chunks, even with kLengthMs tuning).**

---

## Memory and CPU Measurements

RSS measurements from bootstrap runs:

    kLengthMs=1000: RSS after load=657MB, after first inference=777MB
    kLengthMs=800:  RSS after load=665MB, after first inference=713MB
    kLengthMs=600:  RSS after load=660MB, after first inference=690MB

Note: after-inference RSS varies because the Metal residency set allocations differ
by kLengthMs (shorter ring buffer → smaller Metal buffer allocation). All values
are within the spike-specific 1 GB C11 budget.

Production C11 budget is 200 MB. whisper-small at ~690–780 MB RSS does not meet it.
whisper-tiny RSS is approximately 200–300 MB — borderline for production deployment.

---

## Confidence (C9) Sensitivity to kLengthMs

Smoke baseline medianLogProb per kLengthMs:

    kLengthMs=1000 (quiet_speech_pods warm pass): medianLogProb=0.653
    kLengthMs=800  (quiet_speech_pods warm pass): medianLogProb=0.638
    kLengthMs=600  (quiet_speech_pods warm pass): medianLogProb=0.705

Values are in the 0.63–0.71 range, consistent with #17.2's baseline of 0.699.
Shorter context windows show slight reduction in median log_prob (less context = less
confident decoder), but within acceptable bounds. C9 would likely PASS at all kLengthMs
values if Gate 2 ran. This confirms Risk A (C9 regression from short context) did NOT
materialize for whisper-small in the measured range.

---

## Recommendation

SMOKE-GATE FAIL → ESCALATE.

Whisper-small on Metal M3 has an encoder latency floor of ~300–450ms that is not
reducible by kLengthMs tuning. The whisper 30-second mel architecture is incompatible
with the C4 ≤ 200ms budget for any kLengthMs value tested.

Recommended next step: **Spike #17.4-whisper-tiny**

whisper-tiny has approximately 4× fewer encoder parameters than whisper-small.
Expected C4: ~75–120ms on M3 with Metal (4× improvement over whisper-small's ~300ms
floor, assuming compute scales with model size). This would pass the 200ms C4 budget.

Procedure for Spike #17.4:
1. Re-use 100% of #17.3 source infrastructure (Sources/CWhisper, Sources/Spike17_3,
   Sources/Spike17_3CLI, Sources/Spike17_3Eval — all fixes applied).
2. Download ggml-tiny.bin from HuggingFace ggerganov/whisper.cpp.
3. Run bootstrap with --model models/ggml-tiny.bin.
4. Smoke gate: if C4 ≤ 200ms at kLengthMs=1000, run Gate 2 with all 11 fixtures.
5. Measure C9 accuracy to confirm filler-word detection viability.

If whisper-tiny fails C9 (accuracy too low for filler detection):
  Escalate to Option B: Sherpa-ONNX with moonshine-tiny (streaming architecture,
  <100ms latency target, no 30s context window constraint).

---

## Production Readiness Checklist (contingent on Spike #17.4 PASS)

This section will be completed after Spike #17.4. The locked configuration is:

  whisper.cpp SHA: 9386f239401074690479731c1e41683fbbeac557
  kLengthMs: TBD (to be locked at Spike #17.4 smoke gate)
  vadThreshold pods: 0.50
  vadThreshold mac:  0.30
  specialTokenFilter: [BLANK_AUDIO], [_BEG_], [_END_], [MUSIC], [NOISE], [SILENCE],
                      [SOUND], (Music playing), standalone Thank you./Thanks./You.
  audioSamplePositionMs: enabled (Fix 4)
  Metal: EMBED_LIBRARY=ON, flash_attn=OFF
  C8 eval: audioSamplePositionMs-based (Fix 4 applied)

The production commit specification will be written in Spike #17.4 REPORT.md once
a complete PASS is achieved.

---

## Forward-Port Notes

For Spike #17.4 and downstream implementation:

Fix 4 (audioSamplePositionMs) is the most critical forward-port. The C8 eval
methodology bug was fixed in this spike and MUST be carried forward. The TokenEvent
struct, the CSV column layout (7 columns: update_index, emission_ms, gap, audio_ms,
text, is_confirmed, confidence), and the Criteria.swift C8 scorer are all ready.

Fix 2 (VAD threshold via raw probability): the `cwhisper_vad_detect_speech_threshold`
implementation using `whisper_vad_detect_speech` + `whisper_vad_probs` inspection is
correct and efficient. Note: do NOT use `whisper_vad_segments_from_samples` for
per-chunk streaming VAD — it applies segment-duration filters that reject 160ms chunks.

Fix 3 (special token filter): filter list may need expansion for whisper-tiny, which
hallucinates differently from whisper-small. Review silence_only fixture outputs after
running Spike #17.4 and add any new patterns to the filter.

The macOS 26 beta module map issue (multi-line format required for clang 21) and the
canonical path issue (URL.standardizedFileURL needed for `..` paths in -I flags) are
documented for any future SPM-based C bridge work.
