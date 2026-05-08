# Spike #4 Phase 2 — AudioTap Strict-Concurrency Tightening

> **Status:** ✅ passed (S1, S2, S3, S4, S5 — all scenarios complete)
> **Spike directory:** `MicTapTightenSpike/`
> **Depends on:** Spike #4 Phase 1 (Session 008), Spike #7 (Session 012)
> **Serves:** FM4 (no perf impact), FM2 (no silent buffer loss)

---

## Scenario outcomes

=== SCENARIO_OUTCOMES ===
- S1 — 60s baseline: PASS — buffers received: 620; last timestamp: 2971200; format (sample rate / channels): 48000.0 Hz / 1 ch; total samples copied: 2,976,000; one-line observation: steady ~10.3 buffers/sec, zero gaps, sample count = frameLength × channelCount on every buffer
- S2 — Strict-concurrency compile gate: PASS — flags used: swift-tools-version 6.2 (Swift 6 language mode, strict concurrency default) + swiftSettings .unsafeFlags(["-warnings-as-errors"]); compile output: PASS / 0 errors, 0 warnings
- S3 — Thread Sanitizer 60s run: PASS — TSAN warnings: 0; built with `swift build --sanitize=thread`, ran 60s baseline; 618 buffers received, consistent with S1
- S4 — Configuration-change recovery: PASS — trigger: input-device switch (MacBook mic ↔ AirPods); config-change events observed: 2 (#1: 24000.0 Hz / 1 ch, #2: 48000.0 Hz / 1 ch); recovery time (measured from event #2): 196.9ms; buffer flow resumed: yes; crash: no; final buffers: 177; one-line observation: Chrome Meet did NOT trigger the notification in two prior 90s runs (~952 and ~958 buffers, zero events); input-device switch triggered it reliably with two events in rapid succession (to/from AirPods)
- S5 — Backpressure stress 60s with 200ms artificial delay: PASS — expected ~703 callbacks at 48kHz/4096; sink received: 359 (295 during 60s run + 64 drained from stream buffer at shutdown); documented policy: bufferingNewest(64); observed behavior matches policy: yes — stream buffer held exactly 64 elements at capacity, older buffers silently replaced by newer ones; Phase A (50ms delay, 15s) confirmed no backpressure at 151 buffers (~10.1/sec, consumer keeps up)
=== END_SCENARIO_OUTCOMES ===

---

## How M3.1 copies this pattern

**This section leads with the spike's most important architectural deliverable: the `nonisolated` factory function's load-bearing role under the production project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.**

### The `nonisolated` factory function — SPM vs production forms

In SPM packages (this spike), there is no default-MainActor isolation. Top-level functions are `nonisolated` by default. The `nonisolated` keyword on `makeTapBlock` is redundant but harmless:

    // SPM context (this spike) — nonisolated is redundant but present for documentation
    nonisolated func makeTapBlock(
        continuation: AsyncStream<CapturedAudioBuffer>.Continuation
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void { ... }

In the production Xcode project, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes all top-level declarations implicitly `@MainActor`. Without the `nonisolated` keyword, this function would be MainActor-isolated, and the returned closure would inherit that isolation. CoreAudio's `RealtimeMessenger.mServiceQueue` would then invoke a MainActor-isolated closure, causing `_dispatch_assert_queue_fail` at runtime — no compile warning.

    // Production context (M3.1 AudioPipeline) — nonisolated is LOAD-BEARING
    nonisolated func makeTapBlock(
        continuation: AsyncStream<CapturedAudioBuffer>.Continuation
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void { ... }

**M3.1 must copy this function verbatim into `Sources/Audio/AudioTapBridge.swift` (or equivalent).** The `nonisolated` keyword, the `@Sendable` return type, and the closure body pattern (capture only `Sendable` values, copy all data out of `AVAudioPCMBuffer` before yielding) are all load-bearing.

### Canonical pattern code excerpt with commentary

    // AudioTapBridge.swift — the file MUST NOT contain @MainActor types or
    // functions (except the lifecycle manager below). The tap closure factory
    // is a top-level function because its isolation context is the critical
    // correctness property.

    // 1. Sendable value type — crosses the CoreAudio-thread → actor boundary
    nonisolated struct CapturedAudioBuffer: Sendable {
        let frameLength: AVAudioFrameCount
        let sampleRate: Double
        let channelCount: UInt32
        let sampleTime: Int64
        let hostTime: UInt64
        let samples: [[Float]]  // copied from AVAudioPCMBuffer.floatChannelData
    }

    // 2. Tap closure factory — nonisolated is the load-bearing keyword
    //    Captures ONLY the AsyncStream.Continuation (Sendable).
    //    Copies ALL data out of AVAudioPCMBuffer within the callback.
    //    AVAudioPCMBuffer may be reused by Core Audio after the callback returns.
    nonisolated func makeTapBlock(
        continuation: AsyncStream<CapturedAudioBuffer>.Continuation
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, time in
            let frameLength = buffer.frameLength
            let channelCount = buffer.format.channelCount

            var channels: [[Float]] = []
            channels.reserveCapacity(Int(channelCount))

            if let floatData = buffer.floatChannelData {
                for ch in 0..<Int(channelCount) {
                    let ptr = floatData[ch]
                    let channelSamples = Array(
                        UnsafeBufferPointer(start: ptr, count: Int(frameLength))
                    )
                    channels.append(channelSamples)
                }
            }

            let captured = CapturedAudioBuffer(
                frameLength: frameLength,
                sampleRate: buffer.format.sampleRate,
                channelCount: channelCount,
                sampleTime: time.sampleTime,
                hostTime: time.hostTime,
                samples: channels
            )
            continuation.yield(captured)
        }
    }

    // 3. Lifecycle manager — in production, implicitly @MainActor via build setting.
    //    Lifecycle methods (install, recover, stop) run on MainActor.
    //    The tap closure is produced by the nonisolated factory above.
    //    In this spike, @unchecked Sendable enables capture in @Sendable
    //    notification closures. In production, the class is @MainActor and
    //    observes notifications within its own methods (no cross-isolation capture).
    final class AudioTapBridge: @unchecked Sendable {
        private let continuation: AsyncStream<CapturedAudioBuffer>.Continuation
        let bufferStream: AsyncStream<CapturedAudioBuffer>

        init(bufferPolicy: ... = .bufferingNewest(64)) {
            var cont: AsyncStream<CapturedAudioBuffer>.Continuation!
            self.bufferStream = AsyncStream(bufferingPolicy: bufferPolicy) { cont = $0 }
            self.continuation = cont
        }

        func install(on inputNode: AVAudioInputNode) {
            inputNode.installTap(
                onBus: 0, bufferSize: 4096, format: nil,
                block: makeTapBlock(continuation: continuation)
            )
        }

        func recover(engine: AVAudioEngine, inputNode: AVAudioInputNode) {
            inputNode.removeTap(onBus: 0)
            if inputNode.isVoiceProcessingEnabled {
                try? inputNode.setVoiceProcessingEnabled(false)
            }
            inputNode.installTap(
                onBus: 0, bufferSize: 4096, format: nil,
                block: makeTapBlock(continuation: continuation)
            )
            engine.prepare()
            try? engine.start()
        }

        func stop(inputNode: AVAudioInputNode) {
            inputNode.removeTap(onBus: 0)
            continuation.finish()
        }

        deinit { continuation.finish() }
    }

### What changes for M3.1 vs what stays

**Stays verbatim:**
- `CapturedAudioBuffer` struct (add/remove fields as TranscriptionEngine needs evolve, but the `nonisolated struct: Sendable` shape stays)
- `makeTapBlock` function — signature, `nonisolated` keyword, `@Sendable` return type, closure body pattern (copy-then-yield)
- `AsyncStream(bufferingPolicy: .bufferingNewest(64))` construction
- `install` method: `installTap(onBus: 0, bufferSize: 4096, format: nil, block: makeTapBlock(...))`
- `recover` method: remove tap → check VPIO → reinstall with format: nil (same continuation) → prepare → start
- `stop` method: remove tap → finish continuation
- `deinit` safety net: `continuation.finish()`

**Changes for production:**
- Logger: `Logger(subsystem: "com.talkcoach.app", category: "audio")` instead of spike subsystem
- Class name: `AudioPipeline` instead of `AudioTapBridge`
- `@unchecked Sendable` removed — production `AudioPipeline` is `@MainActor` (implicit from build setting) and does NOT need to be Sendable. Config-change notification observation uses `NotificationCenter.default.notifications(named:object:)` async sequence consumed in a `Task` within the `@MainActor` class, avoiding the cross-isolation capture issue the spike worked around.
- `AVAudioEngine` and `AVAudioInputNode` are owned properties of `AudioPipeline`, not `nonisolated(unsafe)` globals. The `@MainActor` class owns the engine's lifecycle.
- `CapturedAudioBuffer.samples` may carry the raw `Data` or `[Float]` depending on what `TranscriptionEngine` needs. The copy-in-callback pattern stays.

---

## Locked hand-off mechanism: AsyncStream continuation

### Choice and rationale

**Selected:** `AsyncStream<CapturedAudioBuffer>` with `Continuation.yield(_:)` in the tap closure.

The continuation's `yield` is `@Sendable`, thread-safe, and non-blocking — safe to call from CoreAudio's real-time render thread. The consumer pulls buffers via `for await buffer in bridge.bufferStream`, which is the idiomatic Swift concurrency pattern for producer-consumer across isolation domains.

Validated by S1 (620 buffers/60s, zero gaps), S3 (TSAN-clean under concurrent CoreAudio + actor access), and S5 (backpressure policy holds under 200ms consumer delay).

### Rejected alternatives

- **Actor method call per buffer (`Task.detached { await sink.process(buffer) }`):** Creates ~11 Task allocations/sec. No built-in backpressure — actor mailbox grows unboundedly if consumer is slow. Task creation on the real-time audio thread risks priority inversion. The AsyncStream absorbs bursts without per-buffer Task overhead.
- **`nonisolated(unsafe)` ring buffer with NSLock:** Zero allocation, lowest latency, but fights Swift 6's concurrency model. Manual synchronization is error-prone and would require a separate signaling mechanism (DispatchSemaphore or similar) to wake the consumer. Not composable with actor-based downstream consumers.
- **Dispatch serial queue:** Well-understood but pre-Swift-concurrency. Doesn't compose with actors without an async bridge. Adds a GCD scheduling hop that AsyncStream avoids.

---

## Locked backpressure policy: `.bufferingNewest(64)`

### Choice and rationale

**Selected:** `AsyncStream.Continuation.BufferingPolicy.bufferingNewest(64)`.

Per Apple's documentation (https://developer.apple.com/documentation/swift/asyncstream/continuation/bufferingpolicy/bufferingnewest(_:)): "When the buffer is full, the oldest element in the buffer is discarded to make room for the new element." This means the 64 newest elements are retained and the consumer always processes the freshest available audio. Stale audio is worse than skipped audio for real-time speech processing.

64 buffers at 48kHz/4096 ≈ 5.5 seconds of audio headroom. Under normal operation (S1: consumer processes buffers with zero delay), the buffer never fills. Under stress (S5: 200ms consumer delay), the buffer fills within seconds and old buffers are silently replaced — the consumer processes ~5 buffers/sec from the newest available, and memory stays bounded.

Validated by S5: 703 expected callbacks, 359 received by sink (295 during 60s + 64 drained at shutdown). The 64-element drain at shutdown exactly matches the policy's capacity, confirming the buffer was full and bounded.

### Rejected alternatives

- **`.bufferingOldest(N)`:** Retains oldest N, drops NEW arrivals when full. Wrong for real-time audio — the consumer would process stale data while fresh audio is discarded.
- **`.unbounded`:** Never drops; queue grows indefinitely. Risk of OOM during extended slow-consumer episodes. Acceptable only if data loss is categorically unacceptable, which it is not for real-time speech metrics.
- **Bounded queue with blocking yield:** Not available in `AsyncStream`. Would require a custom `AsyncChannel`. Blocking the CoreAudio render thread would cause audio dropouts — categorically unacceptable per FM4.

---

## Observations on sample-data copy

The `CapturedAudioBuffer.samples` field carries actual PCM data copied from `AVAudioPCMBuffer.floatChannelData` inside the tap closure. Validated:

- **Correctness (S1):** `totalSamplesCopied = 2,976,000` over 620 buffers at 1 channel × 4800 frames = 4800 samples/buffer. 620 × 4800 = 2,976,000. The `BufferSink` assertion `actualSamples == frameLength × channelCount` passed on every buffer — zero assertion failures.
- **TSAN safety (S3):** Zero TSAN warnings. The `Array(UnsafeBufferPointer(...))` copy creates a new Swift `Array` from the buffer's float pointer within the tap callback. The resulting `[Float]` is a value type in the `Sendable` struct — no shared mutable state crosses the boundary.
- **Real-time thread allocation (S1):** The `Array` allocation inside the tap closure runs on CoreAudio's render thread. At ~10.3 callbacks/sec with 4800 floats (19,200 bytes) per buffer, the allocator handles this without measurable impact — S1 showed zero gaps over 60s. For production, if allocation pressure becomes a concern (e.g., multi-channel high-sample-rate inputs), a pre-allocated buffer pool with `nonisolated(unsafe)` could replace the per-callback `Array` allocation, but the current approach is validated as safe for v1's single-channel 48kHz use case.

---

## S4 findings

### Phase 1 → Phase 2 trigger reproducibility

Spike #4 Phase 1 (Session 008) documented that Chrome Meet joining mid-session triggers `AVAudioEngineConfigurationChange`. Phase 2's S4 harness reproduced the engine-first ordering (engine started → tap installed → 2s warm-up → 90s observation window) but Chrome Meet did NOT fire the notification across two independent 90s runs (~952 and ~958 buffers received, zero config-change events).

Possible causes:

- **Chrome version drift.** Chrome's WebRTC stack periodically changes how it acquires audio devices — newer versions may negotiate shared access without triggering an OS-level configuration change.
- **Harness engine-setup difference.** Phase 1's harness may have used a different `AVAudioEngine` initialization sequence (e.g., different VPIO state, different node topology) that made the system more susceptible to Chrome's audio routing change.
- **macOS behavior change.** Tahoe (macOS 26) may handle concurrent audio clients differently than the macOS version used in Phase 1.

The recovery code path was validated by an input-device switch (MacBook mic ↔ AirPods) instead, which exercises the identical `AVAudioEngineConfigurationChange` notification → `recover()` cycle. M3.1 inherits the validated recovery pattern; the trigger-source question is documented but not blocking.

### S4 recovery-latency measurement: per-event analysis

The input-device switch produced two config-change events in rapid succession:

- CONFIG CHANGE #1 → 24000.0 Hz / 1 ch (switch to AirPods)
- CONFIG CHANGE #2 → 48000.0 Hz / 1 ch (switch back to MacBook mic)

Recovery latency (196.9ms) was logged only after CONFIG CHANGE #2, not after #1. Analysis of the measurement logic (`main.swift:131–143`):

The notification handler spawns one polling Task per config-change event. Each Task captures `preCount = await sink.snapshot().bufferCount` and polls every 10ms for `bufferCount > preCount`. When two events fire in close succession:

1. CONFIG CHANGE #1 fires → `recover()` restarts engine → polling Task #1 spawned.
2. CONFIG CHANGE #2 fires almost immediately → Apple stops the engine again → `recover()` restarts engine → polling Task #2 spawned.
3. Polling Task #1's `preCount` capture (async) races with #2's engine stop. By the time Task #1 executes its first `await sink.snapshot()`, the engine may have already stopped (from #2) and restarted (from #2's recovery).
4. Both polling Tasks eventually detect buffer resumption (from #2's recovery), but they measure elapsed time from their respective `changeTime` captures.

The 196.9ms logged was measured from CONFIG CHANGE #2's timestamp. CONFIG CHANGE #1's independent recovery latency was not isolated because #2 superseded it before the polling Task could complete its measurement cycle.

**Conclusion:** the harness measurement logic produces an unambiguous single-event result only when config changes arrive with enough spacing (>500ms) for the polling Task to complete before the next event. For rapid-fire events (as in a device switch that triggers two changes), the logged latency reflects the LAST event's recovery. For M3.1's `AudioPipeline`, the recovery cycle should either debounce rapid-fire config changes or measure only the final recovery-to-flow-resumed interval, not per-event.

---

## Design notes

### `AudioTapBridge` isolation model

The spike's `AudioTapBridge` is `@unchecked Sendable` (not `@MainActor`) because:
1. SPM packages do not support `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
2. Making the class `@MainActor` in the harness introduces harness-level complexity (capturing non-Sendable `@MainActor` objects in `@Sendable` notification closures) orthogonal to the spike's core validation.
3. The critical isolation boundary — `nonisolated func makeTapBlock` — is validated regardless of the class's isolation.

In production, `AudioPipeline` will be implicitly `@MainActor` via the build setting. It will NOT be `@unchecked Sendable`. The notification observer will use the async `notifications(named:object:)` sequence consumed within the `@MainActor` class's own `Task`, avoiding cross-isolation captures entirely.

### `nonisolated(unsafe)` for AVAudioEngine globals

`AVAudioEngine` and `AVAudioInputNode` are non-Sendable. In `main.swift`, they're declared as `nonisolated(unsafe) let` at top level — the same pattern as MicCoexistSpike. This is necessary because:
1. Top-level `let` in `main.swift` is MainActor-isolated in Swift 6.
2. The engine and node are accessed from both the setup code (MainActor) and captured indirectly via the tap closure (CoreAudio thread).
3. `nonisolated(unsafe)` tells the compiler "I guarantee thread safety externally." The guarantee holds because: setup writes happen-before engine start (which starts callbacks), and teardown happens-after engine stop (which stops callbacks).

In production, `AudioPipeline` will own these as regular stored properties (implicitly MainActor-isolated). The tap closure factory captures only the `AsyncStream.Continuation` (Sendable), never the engine or node.

### Config-change recovery cycle

The `recover` method's sequence is:
1. `inputNode.removeTap(onBus: 0)` — safe on a stopped engine (no crash, no error).
2. Check `inputNode.isVoiceProcessingEnabled` — re-disable if the config change reset it.
3. `inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil, block: makeTapBlock(...))` — uses `format: nil` to pick up the new hardware format. Uses the SAME continuation so the consumer's `for await` loop is uninterrupted.
4. `engine.prepare()` then `engine.start()`.

The `inputNode` is the same object instance after a config change — `AVAudioEngine.inputNode` is a read-only property that returns the engine's fixed input node.

---

## Apple documentation references

- `AsyncStream.Continuation.BufferingPolicy.bufferingNewest(_:)`: https://developer.apple.com/documentation/swift/asyncstream/continuation/bufferingpolicy/bufferingnewest(_:)
- `AVAudioEngine`: https://developer.apple.com/documentation/avfaudio/avaudioengine
- `AVAudioEngineConfigurationChange`: https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchange
