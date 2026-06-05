# Spike #19 — Broadcaster Pause Architectural Test (Session 050)

> Diagnostic spike to determine whether AudioBufferBroadcaster pause + AVAudioEngine swap can preserve Parakeet's bufferTask across a mid-session device change. Outcome: **HYPOTHESIS B CONFIRMED — pause is necessary but not sufficient. The AVAudioEngine tap's AsyncStream finishes when the OS detaches the device, cascading through the broadcaster's drive loop and killing all consumers.**

## Background

Session 050 attempted 12+ M6.8 iterations to deliver transparent mid-session device-switch handling. All failed. The architect's working assumption was that suppression flags at various listener handlers could prevent the false session-end signals during a switch. After 12 iterations of patching listener handlers in different places (`MicMonitor.handleIsRunningChanged`, `AudioProcessProber.handlePollResult`, in-handler `emitStateChange`, etc.), each fix transformed the failure mode rather than eliminating it.

Product owner proposed an alternative: pause the AudioBufferBroadcaster from yielding to consumers during the switch window. This was the highest-leverage unknown — if it worked, it would let us keep Parakeet, VAD, WPM, and the session ALL alive across a device change, with only the AVAudioEngine layer being swapped.

## Question

Can pausing the broadcaster's drive loop yields preserve consumer streams (specifically Parakeet's `bufferTask`) across a mid-session AVAudioEngine teardown + recreation?

## Three hypotheses

**Hypothesis A (best case):** Pause executes. AVAudioEngine tap continues yielding to its AsyncStream during the device transition (or its AsyncStream stays alive even when the engine is mid-swap). Broadcaster drops some buffers but its drive loop never exits. Parakeet's bufferTask continues `for await` without seeing `.finish()`. Resume yields → bufferTask resumes processing.

**Hypothesis B (intermediate):** Pause executes correctly. But the AVAudioEngine's underlying AsyncStream finishes anyway because the OS-level device teardown explicitly tears down the tap. Broadcaster's `for await buffer in source` exits, broadcaster calls `cont.finish()` on consumer continuations, Parakeet's `bufferTask` exits in cascade.

**Hypothesis C (worst case):** Pause never gets a chance — the existing session-end race fires `micDeactivated → endCurrentSession` synchronously in the same call frame as `micDeviceChanged`, collapsing the spike into the same failure mode as the M6.8 baseline.

## Implementation

Local-only spike commit at SHA `0984279` (later amended to include in-handler micDeactivated suppression). Diagnostic-only, no production behavior change beyond gating session-end paths for the spike duration.

**Changes:**

1. `AudioBufferBroadcaster.swift`: add `paused: Bool` flag, `setPaused()` actor method, drive loop gate that skips yields and increments a drop counter, full instrumentation logs (yields every 100, drops every 50, drive-loop exit).

2. `MicMonitorDelegate.swift`: add `micDeviceChanged()` protocol method with default no-op.

3. `MicMonitor.swift`: in `handleDefaultDeviceChanged`, set `deviceChangedSpikeUntil = now + 2.0` as the very first executable line, then call `delegate?.micDeviceChanged()`. In `handleIsRunningChanged`, early-return with spike-log if `now < deviceChangedSpikeUntil`. Inside `handleDefaultDeviceChanged` itself, also gate the in-handler `emitStateChange(running: false)` path (because it fires synchronously in the same call frame and would otherwise collapse to Hypothesis C).

4. `SessionCoordinator.swift`: implement `micDeviceChanged()` → spawn a Task that sets broadcaster paused = true, sleeps 1500ms, sets paused = false.

5. `ParakeetBackend.swift`: add buffer counter in `bufferTask`, log every 100, log final count on exit.

Tests: existing `testDefaultDeviceChangeNewDeviceNotRunningEmitsDeactivation` marked `XCTSkip` for the spike duration since the gate temporarily changes its expected behavior. Test count: 632 pass + 2 skip + 0 fail.

## Smoke result — Hypothesis B confirmed

Smoke captured at session timestamp 02:16:25.x. Verbatim log sequence at the moment of switch:

```
SPIKE: micDeviceChanged received — pausing broadcaster      ← hook fires
SPIKE: in-handler micDeactivated suppressed                  ← in-handler gate works
broadcaster: paused false → true                             ← pause executes
SPIKE: broadcaster paused, sleeping 1500ms                   ← 1500ms window opens
SPIKE: isRunning change suppressed (×4)                      ← isRunning gate works during window

... ~1000ms after pause ...

broadcaster: drive loop EXITING after 264 buffers — source stream finished   ← THE KILLER LINE
AudioBufferBroadcaster: source stream finished — all consumer streams finished
                                                              ← broadcaster fires cont.finish() on consumers

... ~500ms later ...

pk: bufferTask exited at 241 buffers                          ← Parakeet's bufferTask died in cascade
```

Visual: widget showed dashes briefly then stuck in pulsing-warming, never recovered. Session wrapped correctly when speech stopped.

## What the result proves

**The broadcaster's pause is downstream of where the death happens.** The death originates one layer up: when the OS detaches the HW device (`HALPlugIn::StopIOProc 560227702 (!dev)`), AVAudioEngine internally finishes the tap's AsyncStream. That finish propagates through `AudioPipeline.bufferStream` to the broadcaster's `for await buffer in source` loop. Loop exits. Broadcaster calls `.finish()` on every consumer continuation. Every consumer's `for await` exits in cascade.

The broadcaster's `paused: Bool` only controls whether yields HAPPEN. It cannot stop the source stream from finishing. Once finished, the drive task exits — paused or not.

## Architectural conclusion

**To preserve Parakeet's bufferTask (or any consumer) across a device switch, the AsyncStream that consumers read from must outlive the AVAudioEngine that produces buffers into it.** That requires inserting an intermediate stream between the tap and the broadcaster — a stream we own, that we never finish during a switch.

This is Path B (specified in `docs/session-051-bootstrap-pathB.md`):

```
AVAudioEngine tap → engineStream (per-engine, throwaway)
                  → [PUMP task] copies into ...
                  → mediumStream (session-lifetime, we own)
                  → AudioBufferBroadcaster.drive(from: mediumStream)
                  → consumers (unchanged)
```

When the device changes: cancel the pump, recreate the engine, restart the pump from the new engineStream into the SAME mediumStream. Broadcaster never sees the source change. Consumers see a brief gap.

## What this rules out

- Pause-only architectures (Spike #19's exact shape) — disproven.
- "Just patch the listener handlers" architectures — Session 050's 12-iteration history disproved these by exhaustion; Spike #19 explains WHY they all fail (they fight the wrong layer).
- Replacing the broadcaster's source mid-iteration via reflection or AsyncStream trickery — Swift's AsyncStream API doesn't expose source rebinding; a finished stream is finished.

## What this leaves on the table

- **Path B (intermediate-stream pump):** the architecturally correct fix. Specified, locked, targeted for Session 051. Estimated 4–6h.
- **Option A (ship with limitation):** documented behavior "session ends on mic switch, re-activate to resume." 2h. Fallback if Path B fails.
- **Option C (full serialized actor for audio plane):** 1-2 week refactor. Overkill for v1; carried to v1.x notes.

## Cost

- Spike implementation: ~1h (agent).
- Architect spec + plan review + diff audit: ~30min.
- Smoke + log analysis: ~30min.
- Total: ~2h.

The spike's cost is the cheapest part of the Session 050 budget. It produced the only definitive architectural input the session generated.

## Status

CLOSED. Hypothesis B confirmed. Path B specced. Spike commits discarded; baseline at `m5.7-complete`.
