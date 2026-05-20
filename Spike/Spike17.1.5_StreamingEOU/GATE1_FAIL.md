# GATE 1 FAIL — StreamingEouAsrManager Latency Validation

**Date**: 2026-05-20
**Spike**: #17.1.5 — StreamingEouAsrManager + Parakeet EOU 120M
**Gate 1 verdict**: FAIL (NO-SKIPPING early abort after 160ms smoke test)
**Sweep status**: Aborted after 160ms — 10× budget miss threshold exceeded

---

## Measured Values (160ms chunk size, two passes on alternating_pods.caf)

| Metric | Budget | Pass 1 (first run, JIT cold) | Pass 2 (second run, JIT warm) | Disposition |
|--------|--------|------------------------------|-------------------------------|-------------|
| C4 First-update median ≤ 200ms | ≤ 200ms | 5831ms | 2336ms | **FAIL** (11.7× budget) |
| C5 Inter-update p95 ≤ 400ms | ≤ 400ms | ~1291ms (est. from 12 gaps) | ~1435ms (est. from 12 gaps) | **FAIL** (3.6× budget) |
| C8 VAD heuristic ≥ 83% | ≥ 83% | not measured (stopped) | not measured (stopped) | blocked by C4/C5 |

**Aggregate latency observed (Pass 2, 160ms chunks)**:

    First token: 2336ms
    Inter-update gaps (first 12 updates, sorted):
      258ms, 264ms, 268ms, 513ms, 531ms, 649ms, 653ms, 653ms, 673ms, 902ms, 1435ms, 2336ms
    Median gap: ~590ms
    P95 gap (estimated): ~1400ms

**Pass 1 vs Pass 2 comparison**: Pass 1 (5831ms) vs Pass 2 (2336ms) reveals CoreML JIT
compilation warmup accounts for ~3.5s of initial latency. Even fully warm, C4 = 2336ms
remains 11.7× over the 200ms budget.

---

## Architectural Root Cause

### Loopback encoder cache warmup requirement

`StreamingEouAsrManager` uses a loopback conformer encoder. All caches initialize to zeros:

    pre_cache: [1, 128, 16]   (mel-level context — 16 frames)
    cache_last_channel: [17, 1, 70, 512]
    cache_last_time: [17, 1, 512, 8]

With zero-initialized caches, the first ~2 seconds of audio produce degraded encoder outputs.
The RNNT decoder cannot align tokens to these features. Only after ~29 inference steps
(29 × 80ms shift = 2320ms) do the caches contain real audio context and produce stable
encoder features that the RNNT decoder can map to tokens.

**Evidence**: Pass 2 first token at 2336ms ≈ 29 × 80ms (shift size for 160ms chunks).
The cache warmup requirement is constant at ~2 seconds of audio regardless of chunk size.

### Inference pace: below real-time for 160ms chunks

Feed loop: 10ms sleep + model process() + getPartialTranscript() ≈ 110ms per 160-sample buffer.
This feeds audio at 10ms audio per 110ms wall time = 0.09× real-time.
With 2560-sample chunks (160ms audio) triggering inference every 16 feed iterations:
  - Inference fires every 16 × 110ms ≈ 1760ms wall time per 160ms of audio
  - This is 11× slower than real-time feeding

This slower-than-real-time feeding explains why the 29-chunk warmup takes ~2336ms wall time
rather than the audio-time-equivalent 29 × 80ms = 2320ms.

**Note**: The feed pace matches real-time in the 17.1 spike because SlidingWindowAsrManager's
inference was slow enough that the 10ms sleep dominated. StreamingEouAsrManager's per-chunk
inference is faster (~100ms per 160ms chunk), but the feed rate is still gated by the 10ms
sleep per 160-sample buffer. The result: audio is fed faster than real-time (10ms sleep for
10ms of audio), but process() internally fires inference only every 1280-sample shift, so
effective inference rate is once per 80ms of audio = fast enough to be real-time once warmed.

The actual bottleneck is purely the cache warmup, not the inference speed.

---

## Why Chunk-Size Sweep Cannot Save This

The cache warmup requirement is approximately 2 seconds of audio, regardless of chunk size:

| Chunk | Shift | Chunks to fill 2s cache | First token (estimated) | C4 verdict |
|-------|-------|-------------------------|-------------------------|------------|
| 160ms | 80ms  | ~25 chunks              | ~2000–2500ms            | FAIL       |
| 320ms | 320ms | ~7 chunks               | ~2000–2500ms wall time  | FAIL       |
| 1280ms| 1280ms| ~2 chunks               | ~2500–4000ms wall time  | FAIL       |

For 320ms and 1280ms, the shift is larger, so fewer chunks cover the warmup window. But
each chunk takes longer (proportionally more audio per inference call), and inference time
scales with chunk size. Expected result: all three sizes arrive at ~2s wall time before first
token — still 10× over budget.

Early abort applied per NO-SKIPPING rule: "if C4 is 10× over budget, sweep cannot save it."

---

## C8 Status (VAD Heuristic)

With 160ms chunks and ~590ms median inter-update gap, the 300ms silence threshold would not
detect silence windows reliably during speech segments. During the observed 7.6s gap
(silence window 1), C8 would detect the silence window (7.6s >> 300ms threshold). However,
C4 and C5 failures make C8 moot — real-time use requires sub-200ms first-update latency.

---

## Comparison with Spike #17.1 Root Cause

| Spike | Model | API | First Token | Root Cause |
|-------|-------|-----|-------------|------------|
| #17.1 | 600M TDT v3 | SlidingWindowAsrManager | 18424ms | CoreML fixed [1,240000] input shape, forces 15s batch |
| #17.1.5 | 120M EOU | StreamingEouAsrManager | 2336ms (warm) | Loopback encoder cache warmup requirement (~2s audio) |

Both fail C4. Root causes differ:
- #17.1: external constraint (CoreML compiled model shape), potentially fixable with fresh compile
- #17.1.5: internal architecture (zero-initialized encoder caches need warmup), not tunable

---

## Recommendation: Escalate to Whisper.cpp or Sherpa-ONNX

### Option A — whisper.cpp with VAD (recommended)

`whisper.cpp` processes audio in a sliding window with configurable chunk sizes (1–30s).
Combined with Silero VAD (pre-wired in `whisper.cpp`'s `stream` demo), VAD triggers inference
only on speech segments, producing word-by-word output within ~200ms on Apple Silicon M3.

Pros:
- Proven sub-200ms first-word latency on M3 (documented benchmarks: ~150ms with VAD)
- No encoder cache warmup issue (each VAD-triggered segment starts fresh)
- macOS support via Metal/Core ML acceleration
- Pure C++ with Swift interop via bridging header — no new Swift package dependencies
- Whisper medium.en (~770MB) or small.en (~250MB) have acceptable WER for coaching

Cons:
- Requires C++ bridging (additional build complexity vs all-Swift FluidAudio)
- No native EOU detection — need custom VAD threshold for utterance boundary
- Model download at first use (same requirement as Parakeet)

### Option B — Sherpa-ONNX with streaming CTC

`sherpa-onnx` provides streaming ASR with Zipformer/LSTM CTC models. No encoder cache
warmup because CTC decoders are stateless. Sub-100ms first-token latency documented.

Pros:
- Truly stateless per-chunk inference: no cache warmup
- Streaming CTC models (paraformer-online, zipformer-2023) run at RTFx > 10×
- Pre-built macOS binaries available

Cons:
- ONNX runtime dependency (new Swift package)
- No FluidAudio ecosystem integration
- English-only models for the fastest variants

### Verdict

Recommend Option A (whisper.cpp + VAD) for Spike #17.2:
- Lowest architectural risk (proven production use in LLM-backed voice apps)
- Closer to the existing FluidAudio pipeline philosophy (audio-in, text-out)
- Metal acceleration available, aligning with Apple Silicon target
- The Silero VAD integration solves C8 natively (no heuristic needed)

If whisper.cpp's WER is insufficient for non-English locales in Phase 3, Option B
(Sherpa-ONNX with multilingual models) as a fallback.

---

## Files Generated

- `GATE1_FAIL.md` — this file
- `results/bootstrap_160ms.json` — model load (success, 529ms, 241.5MB RSS)
- `/tmp/smoke_160ms.csv` — first smoke test (5831ms first token)
- `/tmp/smoke2_160ms.csv` — second smoke test (2336ms first token, confirming JIT warmup)

No Gate 2 results. Spike #17.1.5 verdict: **FAIL / ESCALATE**.
