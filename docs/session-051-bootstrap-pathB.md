# Session 051 Bootstrap — Path B (Intermediate-Stream Pump) for M6.8

> Closeout from Session 050: 12+ M6.8 iterations failed. Spike #19 proved the architectural fix has to be at the data-flow layer, not the suppression-flag layer. This doc is the load-bearing spec for Session 051.

## Read order at session start

1. `CLAUDE.md`, `docs/00_COLLABORATION_INSTRUCTIONS.md`
2. `docs/01_PROJECT_JOURNAL.md` — Session 050 entry at the top, **read in full**
3. `docs/spikes/spike-19-broadcaster-pause-architectural-test.md` — the spike that pointed at this path
4. **This file**
5. Then: `docs/04_BACKLOG.md` (M6.8 row), `docs/03_ARCHITECTURE.md`

## Baseline state

- HEAD at `3ec9a5b`, tag `m5.7-complete`.
- 633/634 tests passing (1 pre-existing flake `testHoverActive_overridesAlphaTo1`, unchanged).
- All M6.8 work from Session 050 reverted. None of it ever shipped to origin/main.
- Banned symbols (must not return): `isInRewire`, `rewireWarmupUntil`, `applyWPMVoiced`, `onRewireStateChanged`, `rewireInProgress`, `rewireAudioPipeline`, `replaceAudioProvider`.

## Product requirement (locked)

When the default input device changes mid-session:

- Session ID does NOT change. Counters preserved.
- Widget visibly transitions `counting → warming` for the duration of the switch (acceptable artifact, ~1–2s).
- Widget transitions back to `counting` on first new non-nil WPM from the new device.
- If the audio plane restart fails, session ends via normal wrap UX (`.pipelineRestartFailed`).
- **What does NOT happen:** session-restart cascades, stuck-warming, stuck-dashes, 71-second teardowns piling up. Today's baseline failure modes.

## The architectural fix

### Today's data-flow (where the death happens)

```
AVAudioEngine.inputNode.installTap(block:)
  → block yields to AudioPipeline.continuation
    → bufferStream: AsyncStream<CapturedAudioBuffer>   ← created in AudioPipeline.start()
      → AudioBufferBroadcaster.drive(from: bufferStream)
        → cont.yield(buffer) for each consumer continuation
          → ParakeetBackend.bufferTask reads provider.bufferStream()
          → SileroVADGate reads its consumer stream
```

When the OS detaches the HW device (`HALPlugIn::StopIOProc 560227702 (!dev)`), AVAudioEngine internally finishes the tap. The `bufferStream`'s `for await` loop in the broadcaster's drive task exits. The drive task calls `cont.finish()` on every consumer continuation. Parakeet's `bufferTask` sees its `for await` end and exits. Cascade death. Spike #19 proved this empirically with `broadcaster: drive loop EXITING after 264 buffers — source stream finished`.

### Path B: insert a pump

```
AVAudioEngine.inputNode.installTap(block:)
  → block yields to AudioPipeline.engineContinuation              ← per-engine, throwaway
    → engineStream: AsyncStream<CapturedAudioBuffer>              ← per-engine, throwaway
      → [PUMP task] copies buffers from engineStream into ...
        → mediumStream: AsyncStream<CapturedAudioBuffer>          ← session-lifetime, owned by Pipeline
          → AudioBufferBroadcaster.drive(from: mediumStream)      ← UNCHANGED
            → fans out to VAD + Parakeet (UNCHANGED)
```

- `mediumStream` is created once per session in `AudioPipeline.start()` and survives every engine recreation within that session.
- `engineStream` is created per-engine in a new method `AudioPipeline.startEngine()`. When an engine dies, `engineStream` finishes, the pump's `for await` loop exits — but the pump only calls `engineContinuation.finish()` on the per-engine stream, NEVER on `mediumContinuation`.
- When the device changes: cancel the pump task, recreate the engine, install a new tap, start a new pump task copying from the new `engineStream` into the SAME `mediumStream`. The broadcaster's drive task never notices — its `for await buffer in mediumStream` keeps suspending and resuming on new buffers.
- `mediumStream` uses `.bufferingNewest(64)` so a gap during the switch silently drops audio rather than blocking. Parakeet's RollingAudioWindow already handles gaps via the resampling converter; brief gaps produce no tokens for one hop and recover.

### Why this works where Spike #19's broadcaster-pause didn't

Spike #19's pause was DOWNSTREAM of the death. The bufferStream finished, propagating through the broadcaster's drive loop to consumers. Path B's pump is BETWEEN the AVAudioEngine and the broadcaster — engine deaths terminate the pump's iteration but the broadcaster's source (`mediumStream`) stays alive because we never finish its continuation during a switch.

## File-level spec

### Sources/Audio/AudioPipeline.swift — pump + per-session mediumStream

Add session-lifetime stream pair:

```swift
nonisolated(unsafe) private(set) var mediumStream: AsyncStream<CapturedAudioBuffer>
nonisolated(unsafe) private var mediumContinuation: AsyncStream<CapturedAudioBuffer>.Continuation
private var pumpTask: Task<Void, Never>?
```

`init` creates the mediumStream + continuation pair (replacing the current bufferStream pair).

`start()` does NOT recreate mediumStream — only `startEngine()` (new method) creates the per-engine stream and the pump.

`startEngine()`:
1. If `needsEngineRecreateOnNextStart`, call `provider.recreate()`, `waitForHWBoundInputFormat()`.
2. Create per-engine stream + continuation pair (locally — captured into the tap block, not stored on self).
3. `setVoiceProcessingEnabled(false)`.
4. `installTap(format: nil, block: makeTapBlock(continuation: engineContinuation))`.
5. `prepare()` + `engine.start()`.
6. Start the pump task: `for await buffer in engineStream { mediumContinuation.yield(buffer) }`. **Pump never calls `mediumContinuation.finish()`** — only `engineContinuation` finishes when AVAudioEngine dies. Pump task exit just means "no more buffers from this engine."

`stopEngine()` (new method): `pumpTask?.cancel(); await pumpTask?.value`, `provider.removeTap()`, `provider.stop()`, set `needsEngineRecreateOnNextStart = true`.

`switchDevice()` (new method, async): `stopEngine()`, 300ms HAL settle (`Task.sleep`), `try startEngine()`. Throws on engine start failure.

`stop()` (session end): `stopEngine()`, then `mediumContinuation.finish()` — this finishes the session-lifetime stream. The broadcaster's drive loop exits naturally and finishes consumer streams.

### Sources/Audio/AudioBufferBroadcaster.swift — UNCHANGED

The broadcaster reads from `pipeline.mediumStream` instead of `pipeline.bufferStream`, but the broadcaster's own code doesn't change.

### Sources/Core/SessionCoordinator.swift — micDeviceChanged routes to switchDevice

New protocol method on MicMonitorDelegate (already added in M6.8 rebuild, retained from the wisdom):

```swift
func micDeviceChanged()
var isSwitching: Bool { get }
```

`SessionCoordinator.micDeviceChanged()`:
1. Guard `state == .active`, `activePipeline != nil`.
2. Set `isSwitching = true`. `onSwitchStarted?()` fires → widget transitions `counting → warming`.
3. Cancel/drain prior `switchTask` if any (rapid double-switch pattern).
4. `try await activePipeline?.switchDevice()`.
5. On success: 1s stability hold, `isSwitching = false`. Widget transitions naturally to counting on first new WPM.
6. On failure: `endCurrentSession(reason: .pipelineRestartFailed)`. Widget wraps normally.

### Sources/Core/MicMonitor.swift — both gates retained

- `deviceChangeUntil` local 500ms window (set first in `handleDefaultDeviceChanged`, BEFORE any other logic).
- `delegate.isSwitching` gate in `handleIsRunningChanged`.
- In-handler `emitStateChange(running: false)` gate during the spike window.

All three were proven necessary in Session 050. None is sufficient alone. Path B keeps all three.

### Sources/Widget/FloatingPanelController.swift — onSwitchStarted wiring

```swift
sessionCoordinator.onSwitchStarted = { [weak self] in
    self?.wpmCalculator?.clearCurrentWPM()
    self?.viewModel.setActivityState(.warming, reason: "device-switch")
}
```

`clearCurrentWPM()` is critical — stale WPM auto-fires the .warming gate and skips warming visually. Retained from M6.8 rebuild wisdom.

### Sources/Analyzer/WPMCalculator.swift — clearCurrentWPM() method

Single new method that nils the `wpmVoiced` property without affecting session counters.

## Test plan

1. `testSwitch_TransitionsCountingToWarmingThenBackToCounting` — drive coordinator to counting, fire `micDeviceChanged`, assert warming, deliver WPM, assert counting.
2. `testSwitch_PreservesSessionIDAndCounters` — start session, capture sessionID + tokenCount, fire `micDeviceChanged`, assert both preserved.
3. `testSwitch_OnRestartFailure_EndsSessionNormally` — fake provider throws on second `engine.start()`, assert session ends with `.pipelineRestartFailed`.
4. `testSwitch_RapidDoubleSwitch_CancelsInFlight` — fire `micDeviceChanged` twice rapidly, assert only one switch sequence completes.
5. `testMicMonitor_IsRunningSuppressedDuringSwitching` — delegate with `isSwitching=true`, fire isRunning=false, assert no `micDeactivated` call.
6. `testMicMonitor_LocalDeviceChangeWindow_SuppressesIsRunning` — local window suppresses pre-coordinator race.
7. `testAudioPipeline_PumpSurvivesEngineRestart` — start engine, push buffers, restart engine via `switchDevice()`, push more buffers, assert mediumStream consumer received both batches without `.finish()`.
8. `testAudioPipeline_MediumStreamFinishesOnlyOnStop` — `switchDevice()` MUST NOT finish mediumStream; only `stop()` finishes it.

## Smoke acceptance criteria

1. Continuous speech, switch Mac mic → AirPods. Widget cycles `counting → warming → counting`. Session ID preserved. Counters preserved.
2. Continuous speech, switch AirPods → Mac mic. Same.
3. 3-4 round-trip switches in 60s. App remains responsive throughout. Final session ends normally when speech stops.
4. Log shows ZERO occurrences of: `mic-off-listener` during a switch, `pipeline.start failed`, stuck `warming` lasting > 5s, stuck dashes.
5. Log shows: `device switch — tearing down audio plane (entry #N)` for every switch, `switchDevice complete in Nms`, widget-state transitions counting→warming→counting per switch.

## Hard limits for Session 051

- **3-iteration ceiling.** If smoke fails three times consecutively with the bug recurring (not transforming), STOP. Re-architect. Do not iterate beyond 3 in one session.
- **No suppression-flag iteration.** Path B is one architectural change. If smoke shows a new race condition, the answer is NOT to add another suppression flag — it's to revisit the architecture.
- **Banned symbols** (zero occurrences in Sources/): see list at top of this doc. Grep at end of every implementation.
- **One commit local-only**, architect verifies SHA before smoke. Same workflow as M6.8 rebuild.

## Estimate

- 4–6h focused. Implementation surface is small: ~80 net new lines, ~3-line tap-block recapture in AudioPipeline.
- Session 051 should NOT spend > 90 minutes on the pump pattern itself. If it does, the agent is going wrong somewhere.

## What success looks like

End of Session 051: M6.8 pushed to origin/main, tagged `m6.8-complete`, smoke passes all 5 criteria above. Phase 6 unblocks. Next module in queue is M6.6 (performance pass).

## What failure looks like, and what to do

If Path B fails smoke: **stop, journal, do NOT iterate**. We then have two remaining options on the table from Session 050's analysis:
- **Option A**: ship with documented limitation ("session ends on mic switch, re-activate to resume").
- **Option C**: full serialized-actor for the audio plane (1-2 week refactor, deferred until v1.x).

The decision between A and C is a product call by Anton, not an architect-driven iteration.
