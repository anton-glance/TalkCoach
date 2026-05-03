# Spike #4 — Mic Coexistence with Zoom Voice Processing

**Status:** ⚠️ passed with caveats
**Date:** 2026-05-02
**Hardware:** MacBook Pro (Mac15,12), macOS 26.4.1, Apple Silicon, built-in mic, wired Ethernet
**Self-loop:** iPhone joined same call, mic muted, speaker on — user confirmed hearing themselves in all scenarios

---

## Summary

`AVAudioEngine` with `isVoiceProcessingEnabled = false` coexists perfectly with native conferencing apps (Zoom, FaceTime). Browser-based conferencing (Chrome Meet, Safari Meet) works fine when the browser is already in a call before our engine starts, but triggers an `AVAudioEngineConfigurationChange` when the browser joins *after* our engine is running — this stops the engine and requires an explicit restart.

**Production implication:** `AudioPipeline` must observe `AVAudioEngineConfigurationChange` and restart the engine + reinstall the tap. This is a well-documented Apple pattern and straightforward to implement.

---

## Configuration

- `isVoiceProcessingEnabled`: explicitly set to `false` before engine start via `setVoiceProcessingEnabled(false)`
- Input tap: bus 0, bufferSize 4096, format nil (follows hardware format)
- Hardware format: 48000 Hz, 1 channel (built-in mic default)
- No Speech framework, no audio processing — just buffer counting

---

## Results

### Per-scenario detail

#### Scenario B — Baseline (harness alone, no conferencing)

| Metric | Value |
|--------|-------|
| Runtime | 11.5s |
| VPIO | false (all checkpoints) |
| Mean frames/sec | 47,825 |
| Gaps (1s windows with 0 frames) | 0 |
| Config changes | 0 |
| Format | 48000 Hz, 1 ch |

**Verdict: PASS.** Baseline established. ~48000 frames/sec matches 48kHz sample rate.

---

#### Scenario C — Zoom active, then start harness

| Metric | Value |
|--------|-------|
| Runtime | 31.8s |
| VPIO | false |
| Mean frames/sec | 47,930 |
| Gaps | 0 |
| Config changes | 0 |
| Format | 48000 Hz, 1 ch |
| Zoom audio degradation | None (user confirmed) |

**Verdict: PASS.** Identical to baseline.

---

#### Scenario D — Harness first, then join Zoom

| Metric | Value |
|--------|-------|
| Runtime | 67.7s |
| VPIO | false |
| Mean frames/sec | 47,934 |
| Gaps | 0 |
| Config changes | 0 |
| Format | 48000 Hz, 1 ch |
| Zoom audio degradation | None (user confirmed) |

**Verdict: PASS.** Zoom joining mid-session caused zero disruption. Every 1s tick at exactly 48000 frames.

---

#### Scenario E — Toggle Zoom mid-session (leave + rejoin while harness runs)

| Metric | Value |
|--------|-------|
| Runtime | 77.2s |
| VPIO | false |
| Mean frames/sec | 47,990 |
| Gaps | 0 |
| Config changes | 0 |
| Format | 48000 Hz, 1 ch |
| Zoom audio degradation | None (user confirmed) |

**Verdict: PASS.** Three phases (Zoom active → Zoom left → Zoom rejoined), zero disruption throughout.

---

#### Scenario F-Chrome-C — Chrome Google Meet active, then start harness

| Metric | Value |
|--------|-------|
| Runtime | 31.8s |
| VPIO | false |
| Mean frames/sec | 47,930 |
| Gaps | 0 |
| Config changes | 0 |
| Format | 48000 Hz, 1 ch |
| Meet audio degradation | None (user confirmed) |

**Verdict: PASS.** Chrome Meet already active — no impact.

---

#### Scenario F-Chrome-D — Harness first, then join Chrome Google Meet

| Metric | Value |
|--------|-------|
| Runtime | 53.4s |
| VPIO | false |
| Mean frames/sec | 17,072 |
| Gaps | 33 |
| Config changes | 1 |
| Meet audio degradation | None (user confirmed) |

At t=19s Chrome Meet joined. `AVAudioEngineConfigurationChange` fired. Engine stopped (`isRunning: false`). Zero frames from t=20s onward.

**Verdict: FAIL (engine stopped, recoverable).** The engine needs to be restarted after the config change notification. Meet's own audio was unaffected.

---

#### Scenario F-Safari-C — Safari Google Meet active, then start harness

| Metric | Value |
|--------|-------|
| Runtime | 31.8s |
| VPIO | false |
| Mean frames/sec | 47,948 |
| Gaps | 0 |
| Config changes | 0 |
| Format | 48000 Hz, **3 ch** |
| Meet audio degradation | None (user confirmed) |

**Verdict: PASS.** Notable: Safari changed the input format to 3 channels (vs 1 ch in all other scenarios). Harness handled it transparently because the tap used `format: nil`.

---

#### Scenario F-Safari-D — Harness first, then join Safari Google Meet

| Metric | Value |
|--------|-------|
| Runtime | 76.7s |
| VPIO | false |
| Mean frames/sec | 22,026 |
| Gaps | 40 |
| Config changes | 1 |
| Format change | 1 ch → 3 ch |
| Meet audio degradation | None (user confirmed) |

At t=35s Safari Meet joined. Config change fired (format shifted to 3 ch). Engine stopped. Zero frames from t=36s onward.

**Verdict: FAIL (engine stopped, recoverable).** Same pattern as Chrome-D.

---

#### Scenario G-C — FaceTime active, then start harness

| Metric | Value |
|--------|-------|
| Runtime | 31.8s |
| VPIO | false |
| Mean frames/sec | 47,908 |
| Gaps | 0 |
| Config changes | 0 |
| Format | 48000 Hz, 1 ch |
| FaceTime audio degradation | None (user confirmed) |

**Verdict: PASS.** FaceTime (Apple's own VPIO usage) causes zero disruption.

---

#### Scenario G-D — Harness first, then start FaceTime call

| Metric | Value |
|--------|-------|
| Runtime | 56.3s |
| VPIO | false |
| Mean frames/sec | 47,933 |
| Gaps | 0 |
| Config changes | 0 |
| Format | 48000 Hz, 1 ch |
| FaceTime audio degradation | None (user confirmed) |

**Verdict: PASS.** FaceTime joining mid-session caused zero disruption. Identical to Zoom behavior.

---

## Consolidated verdict table

| Scenario | App | Pattern | Gaps | Config Changes | Engine survived | Conferencing degraded | Verdict |
|----------|-----|---------|------|---------------|----------------|----------------------|---------|
| B | None | baseline | 0 | 0 | yes | n/a | PASS |
| C | Zoom | app first | 0 | 0 | yes | no | PASS |
| D | Zoom | harness first | 0 | 0 | yes | no | PASS |
| E | Zoom | toggle | 0 | 0 | yes | no | PASS |
| F-Chrome-C | Chrome Meet | app first | 0 | 0 | yes | no | PASS |
| F-Chrome-D | Chrome Meet | harness first | 33 | 1 | **no** | no | FAIL* |
| F-Safari-C | Safari Meet | app first | 0 | 0 | yes | no | PASS |
| F-Safari-D | Safari Meet | harness first | 40 | 1 | **no** | no | FAIL* |
| G-C | FaceTime | app first | 0 | 0 | yes | no | PASS |
| G-D | FaceTime | harness first | 0 | 0 | yes | no | PASS |

*\*FAIL = engine stopped on config change. Recoverable by restarting engine + reinstalling tap.*

---

## Key findings

### 1. VPIO stays false — confirmed
`isVoiceProcessingEnabled` remained `false` at every checkpoint (before setup, after tap install, after engine start) across all 10 scenarios. macOS never overrode it. The explicit `setVoiceProcessingEnabled(false)` call works as documented.

### 2. Native apps coexist perfectly
Zoom (CoreAudio-based) and FaceTime (Apple VPIO) share the mic with our `AVAudioEngine` without any interference. No config changes, no gaps, no format changes, no audio degradation in either direction.

### 3. Browser-based conferencing triggers config changes
Chrome and Safari both use WebRTC/WebAudio for mic access. When they join a call *after* our engine is running, they modify the audio hardware configuration (Safari even changes channel count from 1 to 3). This fires `AVAudioEngineConfigurationChange`, which stops the engine per Apple's documentation.

When the browser call is already active *before* our engine starts, no config change occurs — the engine starts with the browser's configuration already in effect.

### 4. Conferencing audio is never degraded
In all 10 scenarios, the user confirmed hearing themselves clearly on the iPhone throughout. Our `AVAudioEngine` input tap with VPIO disabled is invisible to all tested conferencing apps.

### 5. Safari changes channel count
With Safari Meet active, the input format shifts from 1 channel to 3 channels. Using `format: nil` in `installTap` (which follows the hardware format) handles this transparently. Production code must not hardcode mono.

---

## Production requirements for AudioPipeline

Based on these findings, `AudioPipeline` must:

1. **Observe `AVAudioEngineConfigurationChange`** and, on receipt:
   - Remove the existing tap
   - Re-read the new hardware format
   - Reinstall the tap with `format: nil`
   - Restart the engine
   - Log the event via `os.Logger` (category: `audio`)

2. **Never hardcode channel count or sample rate.** Use `format: nil` for the tap and read format from the buffer in the callback.

3. **Set `isVoiceProcessingEnabled = false`** before any tap installation or engine start. This is the load-bearing configuration for coexistence.

---

## Harness implementation notes

The harness required two non-obvious fixes for Swift 6 strict concurrency on macOS 26:

1. **`@main struct` + audio tap closure = runtime crash.** Swift 6 infers `@MainActor` isolation on closures in `main.swift` top-level code and `@main struct` entry points. The audio tap runs on CoreAudio's `RealtimeMessenger.mServiceQueue`, triggering `_dispatch_assert_queue_fail` at runtime. **Fix:** define the tap closure in a separate source file (`TapHandler.swift`) outside the main-actor context.

2. **`AVAudioEngine` / `AVAudioInputNode` captured in closures from `main.swift`.** These are non-Sendable types. Top-level `let` bindings in `main.swift` are main-actor-isolated in Swift 6. **Fix:** annotate with `nonisolated(unsafe)`.

These are relevant to production `AudioPipeline` design — the audio tap callback must not inherit `@MainActor` isolation.
