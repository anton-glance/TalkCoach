# Spike #17.1 — Parakeet TDT v3 via FluidAudio: macOS Feasibility Report

**FluidAudio version:** 0.14.7 (SHA `8048812869b0c7c6fa393e564a4fb6f95126ba23`)
**Model:** `FluidInference/parakeet-tdt-0.6b-v3-coreml` (JointDecisionv3.mlmodelc)
**Overall verdict:** FAIL / ESCALATE

---

## Verdict summary

C4 First-update latency median ≤ 200ms: FAIL — 18424ms median across 9 clips
C5 Inter-update p95 ≤ 400ms: FAIL — 20761ms p95 across 21 gaps
C8 VAD heuristic accuracy ≥ 90%: FAIL — 2/6 windows detected (33%)

Root cause of all three: the CoreML Preprocessor model is compiled with a fixed
input shape of [1, 240000] (exactly 15 seconds at 16 kHz). FluidAudio's default
`SlidingWindowAsrConfig` constructs windows of 432000 samples (15s chunk + 10s left
+ 2s right context), exceeding the model shape and causing CoreML to reject the
input. Workaround: zero-context config (leftContextSeconds: 0, rightContextSeconds: 0)
produces windows of exactly 240000, but forces 15-second batch processing. The
15-second update cadence is incompatible with the real-time coaching latency budget.

---

## Validation questions V1–V10

V1 — macOS 26 + FluidAudio 0.14.7 build: PASS
    swift build -c release completes in < 2s after package resolution.
    No linking errors, no unavailable APIs. macOS 26 target satisfied.

V2 — loadModels() on macOS: PASS
    AsrModels.downloadAndLoad() returns cleanly. Model loaded in 119ms from cache,
    490ms on first compile from downloaded .mlpackage files.
    No AVAudioSession calls needed or attempted on macOS — FluidAudio does not
    configure the audio session; TiltTalk's wrapper did that (iOS-only concern).

V3 — Incremental updates before audio end: PARTIAL PASS
    C3 disposition is PASS — all 9 speech clips emitted at least one update before
    audio feed ended. However "streaming" means 15-second batches, not sub-second
    updates. The model processes a full 15s window before emitting any token.
    First update arrives at ~18s (after the model finishes its first window).
    This is batch-mode behavior, not streaming, despite the API name.

V4 — Transcribes real_world_test.caf with ≥1 word: PASS
    4 updates from real_world_test; recognizable English speech in each.

V5 — No AVAudioSession conflict on macOS: PASS
    FluidAudio never calls AVAudioSession. AudioSource.microphone on macOS is
    purely a label; actual audio is pushed via streamAudio(). No conflict risk.

V6 — Cafe noise + distractor resilience: PASS
    cafe_noise_pods sample: "Play confine noise, YouTube click from y" /
    "YouTube clip from the iPhone to another" — recognizable despite background.
    C10 disposition PASS.

V7 — Native VAD exposed: NO
    SlidingWindowAsrManager does not expose silence/speech boundaries.
    FluidAudio has a VadManager submodule (Silero VAD) but it is not wired into
    the SlidingWindow path. v7NativeVADAvailable = false.

V8 — updateStream terminates cleanly after finish(): BLOCKED
    SlidingWindowAsrManager.finish() calls inputBuilder.finish() and awaits
    recognizerTask, but never calls updateContinuation?.finish(). The
    AsyncStream stays open indefinitely after finish() returns.
    Workaround: after the feed task completes, call group.cancelAll() to
    cancel the collect task. AsyncStream.Iterator.next() respects cancellation
    and returns nil. This workaround is in processAudioFile().

V9 — Per-token confidence + isConfirmed accessible: PASS (with finding)
    Anton's Q2/Q3 stated "no per-token confidence exists." Actual FluidAudio
    0.14.7 SlidingWindowTranscriptionUpdate has confidence: Float (0.0–1.0) and
    isConfirmed: Bool on every update. TiltTalk's wrapper abstraction hid these.
    Median confidence across confirmed updates: 0.94.
    34/34 updates have confidence ≥ 0.0. 21 confirmed, 13 unconfirmed.

V10 — Peak RSS ≤ 150 MB: PASS
    Peak RSS: 78.9 MB. Well within budget. TiltTalk reported 116 MB on iOS;
    macOS footprint is lower.

---

## 12 criteria table

| # | Name                              | Budget              | Measured                              | Disposition |
|---|-----------------------------------|---------------------|---------------------------------------|-------------|
| 1 | Build/install                     | clean build         | build succeeded (bootstrap.json)      | PASS        |
| 2 | Model load                        | pipeline returned   | loaded in 119ms                       | PASS        |
| 3 | Streaming behavior                | ≥1 update before end| all 9 speech clips                    | PASS        |
| 4 | First-update latency median ≤200ms| ≤ 200ms             | 18424ms median (9 clips)              | FAIL        |
| 5 | Inter-update p95 ≤ 400ms          | ≤ 400ms             | 20761ms p95 (21 gaps)                 | FAIL        |
| 6 | No catastrophic hallucinations    | 0 pattern matches   | 0 matches                             | PASS        |
| 7 | Silence handling                  | 0–1 empty updates   | silence_only: 0–1 empty              | PASS        |
| 8 | VAD heuristic accuracy ≥ 90%      | ≥ 90%               | 2/6 windows (33%)                     | FAIL        |
| 9 | Confidence + isConfirmed          | ≥95% populated      | 34/34; median conf=0.94               | PASS        |
|10 | Cafe noise resilience             | ≥1 word per clip    | recognizable speech in samples        | PASS        |
|11 | Memory ≤ 200 MB                   | ≤ 200 MB RSS        | 78.9 MB peak                          | PASS        |
|12 | Real-world cross-validation       | incremental updates | 4 updates from real_world_test        | PASS        |

---

## Root cause analysis

### Model shape constraint

The Preprocessor CoreML model is compiled with a fixed input:
    func main<ios17>(tensor<fp32, [1, 240000]> audio_signal)

This was compiled by TiltTalk's FluidAudio instance and also matches the model
in FluidInference/parakeet-tdt-0.6b-v3-coreml on HuggingFace. The fixed 240000
sample (15s) input means any configuration that produces windows ≠ 240000 fails
with CoreML shape mismatch.

FluidAudio 0.14.7's default SlidingWindowAsrConfig (chunkSeconds: 15, leftContextSeconds: 10,
rightContextSeconds: 2) produces windows of up to 432000 samples. padAudioIfNeeded()
only zero-pads UP to 240000, never truncates — windows > 240000 pass through
unmodified and CoreML rejects them.

Workaround applied: zero-context config (left=0, right=0, chunk=15s) produces
exactly 240000 samples per window. padAudioIfNeeded handles tail windows < 240000.

### Batch mode consequence

With 15-second chunks and zero context, the pipeline:
1. Accumulates 15 seconds of audio before calling the Preprocessor
2. Runs encoder + TDT decoder on the batch
3. Emits tokens

First update arrives at ~18s (15s accumulation + ~3s inference and streaming overhead).
Subsequent updates every ~20s. This is batch mode, not streaming.

The streaming latency requirement of ≤200ms (C4) and ≤400ms inter-update (C5) are
incompatible with 15-second chunk processing. C8 (VAD) also fails because the
300ms silence threshold cannot detect gaps in a 20s update cadence.

---

## Escalation path: how to reach PASS

Option A — Fresh model download with shorter chunk compilation
    FluidAudio's downloadAndLoad() downloads .mlpackage source from HuggingFace
    and compiles it with CoreML. If the .mlpackage supports flexible or shorter
    fixed input shapes, a freshly compiled model would accept smaller chunks.
    Network bandwidth required: ~614 MB. Not attempted in this spike (slow network).
    Recommendation: run on a fast network, wipe the v3 caches, let FluidAudio compile.
    Risk: the HuggingFace model may also have fixed 240000 shape baked in.

Option B — StreamingEouAsrManager (FluidAudio's alternative)
    FluidAudio 0.14.7 contains StreamingEouAsrManager (EOU = End of Utterance)
    with 160ms, 320ms, 1280ms chunk sizes. These use separate HuggingFace repos
    (parakeet-realtime-eou-120m-coreml). Smaller model (120M vs 600M), separate
    download, but designed for real-time chunk processing. Not evaluated in this spike.
    Latency budget may be achievable with 160ms chunks.

Option C — Use SlidingWindowAsrManager with non-zero context and a freshly compiled
    flexible-shape model. If the .mlpackage compiles to a model accepting variable-
    length input (using CoreML flexible shapes), the full context config would work.
    This is the configuration TiltTalk uses in production. TiltTalk works, which
    suggests either the iOS model has flexible shapes or TiltTalk uses a different
    config. Investigation required.

---

## Bugs found in FluidAudio 0.14.7

Bug 1 — padAudioIfNeeded does not truncate oversized inputs
    AsrManager+Pipeline.swift padAudioIfNeeded returns the array as-is when
    count >= targetLength. For windows > 240000, this feeds oversized arrays to
    CoreML, causing shape mismatch. Expected: truncate or error explicitly.

Bug 2 — finish() does not close updateContinuation
    SlidingWindowAsrManager.finish() awaits recognizerTask but never calls
    updateContinuation?.finish(). Callers must cancel the collect task manually.
    TiltTalk likely worked around this by cancelling the Task that held the
    for-await loop when ending a session.

---

## Infrastructure blockers encountered

1. DispatchSemaphore deadlock (fixed): original main.swift used DispatchSemaphore
   to bridge async to sync. MainActor was blocked while FluidAudio's progress
   handler dispatched back to MainActor. Fixed by replacing with @main async entry.

2. FluidAudio default config shape mismatch (fixed by zero-context workaround):
   SlidingWindowAsrConfig.default produces 432000-sample windows; model accepts
   240000. Zero-context workaround reduces windows to 240000.

3. updateStream non-termination (fixed by group.cancelAll()): finish() doesn't
   close the continuation; added group.cancelAll() after feed task completes.

4. Range crash on zero confirmed rows (fixed): 1..<0 crash in buildClipResult for
   silence-only fixtures. Fixed with confirmedRows.indices.dropFirst().
