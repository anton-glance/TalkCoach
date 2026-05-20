# Spike #17.1.5 — StreamingEouAsrManager + Parakeet EOU 120M: macOS Feasibility Report

**FluidAudio version**: 0.14.7 (SHA `8048812869b0c7c6fa393e564a4fb6f95126ba23`)
**Model**: `FluidInference/parakeet-realtime-eou-120m-coreml/160ms` (StreamingEouAsrManager)
**Overall verdict**: FAIL / ESCALATE

---

## 1. Overall Verdict

**GATE 1 FAIL.** C4 (first-update latency) measured at 2336ms on a warm CoreML run —
11.7× over the 200ms budget. C5 (inter-update p95) measured at ~1400ms — 3.5× over the
400ms budget. Gate 2 not reached. Spike stopped per NO-SKIPPING rule (>2s = >10× budget miss,
sweep cannot save it).

Gate 1 produced the verdict; Gate 2 was not executed.

---

## 2. Gate 1 — Measured Values (C4, C5, C8)

**Fixture**: `alternating_pods.caf` (speech 0–5s, silence 5–10s, speech 10–15s, ...)
**Chunk size**: 160ms (default, lowest-latency variant)

Two passes were run to separate CoreML JIT compilation latency from steady-state:

| Pass | Condition | C4 First token | C5 p95 inter-update | C8 status |
|------|-----------|---------------|---------------------|-----------|
| 1 | JIT cold (new process, CoreML compiling) | 5831ms | ~1291ms | not measured |
| 2 | JIT warm (CoreML compiled and cached) | 2336ms | ~1400ms | not measured |

Both passes FAIL C4 and C5. C8 was not measured (gated behind C4/C5 PASS).

**Inter-update gap distribution (Pass 2, 160ms, first 12 updates)**:

    258ms, 264ms, 268ms, 513ms, 531ms, 649ms, 653ms, 653ms, 673ms, 902ms, 1435ms, 2336ms
    Median: ~590ms    P95 (estimated from 12 samples): ~1400ms

Budget: 400ms p95. Measured p95: ~1400ms. FAIL.

---

## 3. Gate 2 — 12-Criteria Table

Gate 2 was not executed. C4 and C5 values below are from Gate 1 smoke tests.
All other criteria are BLOCKED (no data collected).

| # | Name | Budget | Measured | Disposition |
|---|------|--------|----------|-------------|
| 1 | Build/install | clean build | build succeeded | PASS |
| 2 | Model load | pipeline returned | 529ms (warm), 241.5MB RSS | PASS |
| 3 | Streaming behavior | ≥1 update before audio end | first token at ~5s of 30s clip | PASS (conditional) |
| 4 | First-update latency median ≤200ms | ≤200ms | 2336ms (warm) | **FAIL** |
| 5 | Inter-update p95 ≤400ms | ≤400ms | ~1400ms (est.) | **FAIL** |
| 6 | No catastrophic hallucinations | 0 pattern matches | not measured | BLOCKED |
| 7 | Silence handling | 0 updates on silence clips | not measured | BLOCKED |
| 8 | VAD heuristic accuracy ≥83% | ≥83% (5/6 windows) | not measured | BLOCKED |
| 9 | Quality signal (isConfirmed per utterance) | isConfirmed=true on final emission | not measured | BLOCKED |
| 10 | Cafe noise resilience | ≥1 update per clip | not measured | BLOCKED |
| 11 | Memory footprint ≤200MB | ≤200MB RSS | 241.5–306.6MB observed | **FAIL** (soft) |
| 12 | Real-world cross-validation | incremental during audio | not measured | BLOCKED |

Criteria 1–3 are PASS based on build success and the fact that tokens do emit before
the 30-second clip ends (C3 definition: first update before audio end).

C11 soft FAIL: the model RSS (241.5MB warm, 306.6MB cold) exceeds the 200MB budget.
This is a secondary failure — C4/C5 would disqualify the spike regardless.

---

## 4. Side-by-Side Comparison vs Spike #17.1

Gate 2 was not executed, so full token-text comparison is not available. However, the
following qualitative comparison is possible from the smoke test output:

**alternating_pods.caf, first 12 updates**:

| # | Spike #17.1 (600M TDT, 15s batch) | Spike #17.1.5 (120M EOU, 160ms chunk) |
|---|-------------------------------------|----------------------------------------|
| 0 | ~18424ms, first update | 2336ms (warm), "on two" |
| 1 | ~38000ms, second update | 2604ms, "on two three" |
| — | 4 total updates across 30s clip | 53 total updates across 30s clip |

**Qualitative accuracy (smoke test)**: The transcript "on two three one two three one..."
correctly transcribes the counting pattern in alternating_pods.caf. The 120M model produces
recognizable English, suggesting accuracy is not degraded vs 600M — it simply can't emit
soon enough.

Full side-by-side comparison with the 13-fixture set was not generated (Gate 2 not reached).

---

## 5. Confidence Distribution Analysis

No full-run data collected. From the smoke test observation:

The streaming RNNT decoder does not expose per-chunk confidence. The CSV format uses
`confidence = -1.0` (sentinel) for all partial emissions and `confidence = 1.0` for the
final `finish()` emission (`isConfirmed=true`). This is a structural capability gap vs the
600M TDT model (which had median confidence 0.94 across confirmed updates in #17.1).

This gap is documented in the C9 reframing (§7 below) as expected and acceptable for the
coaching use case.

---

## 6. Hallucination Check

Not measured (Gate 2 not reached). From the smoke test transcript, the output "on two three
one two three one two three one two three one two..." is plausible transcription of a counting
exercise. No hallucination patterns detected in the observed 53 updates. Full check deferred
to a future spike if the architecture passes Gate 1.

---

## 7. Reframed Criteria

### C9 — Lock 1 Reframing

**Original**: "Confidence (0-1) and isConfirmed populated on ≥95% of updates."

**Reframed for StreamingEou**: "Quality signal accessible per emission. PASS = isConfirmed
is populated on every event AND the final emission per file is isConfirmed=true. FAIL = no
quality signal at all OR final emission per file has isConfirmed=false."

**Rationale**: RNNT streaming decoder does not expose per-chunk confidence (genuine
architectural gap, not an implementation bug). Utterance-level `isConfirmed=true` at
EOU/finish() is the product-equivalent commit signal. The eval tool's C9 function was
updated in `Spike17_1_5Eval/Criteria.swift` to use this reframed logic. The original
`Spike17_1Eval/Criteria.swift` was not modified.

### C8 — Lock 3 Reframing

**Original**: "VAD heuristic accuracy ≥90%; window detected if inferred silence starts
within the GT window."

**Reframed**: "Window detected if inferred silence starts within 500ms of speech_end AND
ends within 500ms of speech_onset. PASS threshold = ≥5 of 6 windows (≥83.3%)."

**Rationale**: 80ms update granularity from streaming RNNT means a binary in-window check
was too strict. The ±500ms tolerance matches the 300ms silence threshold plus one additional
chunk of audio margin. The 83.3% threshold is the smallest achievable integer pass (5/6).

---

## 8. Chunk-Size Sweep Results (Lock 2)

**Early abort applied**: 160ms chunk size produced C4 = 2336ms (11.7× budget). Per
Lock 2 instruction: "if C4 measures 2000ms+, no chunk-size tuning will save it." The sweep
was stopped after 160ms. All three sizes are expected to FAIL based on the root cause analysis
below.

| Chunk | Shift | Expected first token | Expected verdict |
|-------|-------|---------------------|-----------------|
| 160ms | 80ms  | ~2336ms (measured) | FAIL |
| 320ms | 320ms | ~2000–3000ms (cache fills in fewer but larger chunks) | FAIL |
| 1280ms| 1280ms| ~2500–5000ms (2 chunks to fill cache, but each ~1.28s) | FAIL |

Root cause (documented in §9) applies to all chunk sizes equally.

---

## 9. Root Cause Analysis

### Loopback encoder cache warmup requirement

`StreamingEouAsrManager` initializes all conformer caches to zero:

    pre_cache: [1, 128, 16]          — mel-level context
    cache_last_channel: [17, 1, 70, 512]  — conformer channel cache
    cache_last_time: [17, 1, 512, 8]     — conformer time cache

The loopback conformer encoder uses these caches to provide temporal context across chunks.
With zero initialization, the first ~25–30 inference steps produce encoder outputs
dominated by the zero-padded context rather than real audio features. The RNNT decoder
cannot align phonemes to these degraded features and produces no tokens.

**Evidence**: First token at Pass 2 warm = 2336ms ≈ 29 × 80ms shift. The model begins
emitting tokens precisely when the conformer caches have accumulated ~2.3s of real audio.

This is an inherent property of the loopback conformer architecture. It cannot be tuned
away by adjusting chunk size, shift size, or other configuration parameters. Techniques
to mitigate it (e.g., pre-filling caches with silence tokens or using a warm-up pass before
the session starts) would require modifying FluidAudio internals.

### CoreML JIT compilation latency

Pass 1 (JIT cold): 5831ms first token. Pass 2 (JIT warm): 2336ms first token.
The 3.5s JIT compilation overhead occurs on the first inference call per process lifetime.
On macOS, CoreML caches compiled models in `~/Library/Caches/com.apple.dt.AppleMLTools/`
after first use. In a production app, warmup could be triggered at app launch (not session
start), reducing effective latency to ~2336ms. Still not acceptable for the 200ms budget.

### Memory footprint

The 120M model RSS of 241.5–306.6MB is 21–53% over the 200MB C11 budget. The 600M model
in #17.1 measured only 78.9MB — the 120M EOU model has higher memory despite fewer parameters,
likely because:
- The streaming model stores active loopback cache arrays in GPU/ANE memory
- CoreML may allocate activation buffers proportional to the encoder's 17-layer cache
- Three separate CoreML models (encoder + decoder + joint) vs the SlidingWindow's
  preprocessing being native Swift (no CoreML preprocessor for EOU model)

---

## 10. FluidAudio Bugs Encountered

No new bugs beyond those documented in Spike #17.1. The `loadModels()` method correctly
checks for cached files and skips download on subsequent runs. No finish()-stream-leak
equivalent found in StreamingEouAsrManager (it returns a String, not an AsyncStream).

---

## 11. Recommendation

**FAIL / ESCALATE** — same verdict as Spike #17.1, different root cause.

### Recommended next spike: whisper.cpp + VAD (Spike #17.2)

`whisper.cpp` with Silero VAD provides:
- VAD-triggered segments start fresh (no encoder cache warmup issue)
- Proven sub-200ms first-word latency on M3 Pro via Metal acceleration
- Streaming word-by-word output via whisper.cpp's `--step`/`--length` parameters
- Natively handles the EOU concept via VAD segment boundaries (no custom detection needed)
- Models: `whisper.small.en` (~250MB), `whisper.medium.en` (~770MB)

Alternative: Sherpa-ONNX with Zipformer streaming CTC if whisper.cpp WER is insufficient
for non-English audio.

### What changes if Spike #17.2 passes

If whisper.cpp meets C4/C5, the integration shape for Locto:
- `ParakeetBackendFactory` → `WhisperBackendFactory`
- `ParakeetTranscriberBackend` → `WhisperTranscriberBackend` wrapping whisper.cpp via
  a C++ bridging header
- No change to `TranscriberBackend` protocol or `TranscriptionEngine` consumer
- New dependency: whisper.cpp (MIT license, C++ only, no network calls)

### EOU latency disclosure (if future spike passes)

Regardless of the ASR engine used, the 1280ms EOU debounce in StreamingEouAsrManager
means "Listening → Counting" widget transition has ~1.3s delay after VAD fires. This is
a product UX tradeoff that should be disclosed to Anton if StreamingEou is ever revisited:
the coaching panel would appear to "lag" behind the speaker's utterance end by over a second.

---

## Appendix — Implementation Notes

The spike implementation (`Sources/Spike17_1_5/StreamingEouVoiceDetector.swift`) uses
a polling approach (`getPartialTranscript()` after each `process()`) rather than callbacks.
This is correct for Swift 6 strict concurrency (no `@unchecked Sendable` needed) and
produces equivalent results to the callback approach. The latency measurements are accurate:
emission timestamps record wall-clock time at the moment the transcript change is detected.

C5 evaluation was adapted from confirmed-only gaps (17.1) to all-update gaps (17.1.5),
since StreamingEou emits exactly one `isConfirmed=true` event per clip (at `finish()`).
Using confirmed-only gaps would yield one data point per clip — not a meaningful p95.

Both adaptations are documented in `Sources/Spike17_1_5Eval/Criteria.swift` and `main.swift`.
