import XCTest
@testable import TalkCoach

/// M3.7.6 gate close-criterion test.
///
/// Verifies the complete gate behaviour — raw transitions, debounce filtering,
/// audio-time timestamps, and the WPM-vs-Monologue gap divergence — using
/// _testProcessFrame to drive the state machine directly without live audio.
///
/// Frame timeline (512 samples @ 16 kHz = 32 ms per frame):
///
///   Block 1:  63 speech (frames   1–63)  → speechStarted  at frame   1 (t =   0.032 s)
///   Pause A:   4 silence (frames  64–67)  → NO transition  (< 5 debounce frames)
///   Block 2:  63 speech (frames  68–130) → no new transition (already speaking)
///   Pause B:  32 silence (frames 131–162) → speechStopped  at frame 135 (t =   4.320 s)
///   Block 3:  63 speech (frames 163–225) → speechStarted  at frame 163 (t =   5.216 s)
///   Pause C:  69 silence (frames 226–294) → speechStopped  at frame 230 (t =   7.360 s)
///   Block 4:  63 speech (frames 295–357) → speechStarted  at frame 295 (t =   9.440 s)
///   Pause D:  94 silence (frames 358–451) → speechStopped  at frame 362 (t =  11.584 s)
///   Block 5:  63 speech (frames 452–514) → speechStarted  at frame 452 (t =  14.464 s)
///
///   Total frames: 514.  Total transitions: 7 (4 starts + 3 stops).
///
/// Stop-start gaps (speechStopped → next speechStarted):
///   gap1 (Pause B):  5.216 − 4.320 =  0.896 s   → < 2 s (no WPM, no Monologue reset)
///   gap2 (Pause C):  9.440 − 7.360 =  2.080 s   → ≥ 2 s, < 2.5 s (WPM fires, Monologue does not)
///   gap3 (Pause D): 14.464 − 11.584 = 2.880 s   → ≥ 2.5 s (both WPM and Monologue fire)
///
/// RED phase: _updateDebounce is a stub no-op → 0 events emitted → all assertions fail.
final class SileroVADGateCloseCriterionTests: XCTestCase {

    private struct FixedFrameProcessor: VADFrameProcessor, Sendable {
        nonisolated func processFrame(_ samples: [Float]) -> Float { 0.0 }
        nonisolated func reset() {}
    }

    private func driveFrames(_ gate: SileroVADGate, count: Int, prob: Float) async {
        for _ in 0..<count { await gate._testProcessFrame(prob) }
    }

    // MARK: - M3 close criterion

    // swiftlint:disable:next function_body_length
    func testGateM3CloseCriterionTwoStubSubscribers() async {
        let gate = SileroVADGate(frameProcessor: FixedFrameProcessor())

        let collectionTask = Task {
            var events: [VADTransitionEvent] = []
            for await event in gate.transitionStream { events.append(event) }
            return events
        }

        await driveFrames(gate, count: 63, prob: 0.9)  // Block 1
        await driveFrames(gate, count: 4, prob: 0.0)   // Pause A — must NOT emit stop
        await driveFrames(gate, count: 63, prob: 0.9)  // Block 2
        await driveFrames(gate, count: 32, prob: 0.0)  // Pause B
        await driveFrames(gate, count: 63, prob: 0.9)  // Block 3
        await driveFrames(gate, count: 69, prob: 0.0)  // Pause C
        await driveFrames(gate, count: 63, prob: 0.9)  // Block 4
        await driveFrames(gate, count: 94, prob: 0.0)  // Pause D
        await driveFrames(gate, count: 63, prob: 0.9)  // Block 5

        await gate.stop()
        // transitionStream is long-lived (stop() no longer finishes it).
        // Yield so collectionTask drains the already-buffered events, then cancel
        // to unblock it from waiting on the empty stream.
        for _ in 0..<5 { await Task.yield() }
        collectionTask.cancel()
        let events = await collectionTask.value

        // ── AC-G1: exactly 7 transitions
        XCTAssertEqual(events.count, 7, "expected 7 total transitions (4 starts + 3 stops)")

        // ── AC-G2: alternating start/stop pattern beginning with start
        let starts = events.filter { if case .speechStarted = $0 { return true }; return false }
        let stops = events.filter { if case .speechStopped = $0 { return true }; return false }
        XCTAssertEqual(starts.count, 4, "expected 4 speechStarted events")
        XCTAssertEqual(stops.count, 3, "expected 3 speechStopped events")

        guard events.count == 7 else { return }

        func extractTime(_ event: VADTransitionEvent) -> TimeInterval {
            switch event {
            case .speechStarted(let time): return time
            case .speechStopped(let time): return time
            }
        }

        let ts0 = extractTime(events[0])  // speechStarted  frame 1
        let ts1 = extractTime(events[1])  // speechStopped  frame 135
        let ts2 = extractTime(events[2])  // speechStarted  frame 163
        let ts3 = extractTime(events[3])  // speechStopped  frame 230
        let ts4 = extractTime(events[4])  // speechStarted  frame 295
        let ts5 = extractTime(events[5])  // speechStopped  frame 362
        let ts6 = extractTime(events[6])  // speechStarted  frame 452

        let frameMs = Double(SileroVADGate.frameSamples) / 16_000.0  // 0.032

        // ── AC-G3: first speechStarted at audio-time frame 1
        XCTAssertEqual(ts0, 1 * frameMs, accuracy: 1e-9, "speechStarted must be at frame 1 (audio time)")

        // ── AC-G4: Pause A (4 frames) must not emit speechStopped — verified implicitly
        // by events[1] being speechStopped from Pause B, not Pause A.

        // ── AC-G5: speechStopped from Pause B at frame 135
        XCTAssertEqual(ts1, 135 * frameMs, accuracy: 1e-9, "Pause B: speechStopped at frame 135")

        // ── AC-G6: speechStarted from Block 3 at frame 163
        XCTAssertEqual(ts2, 163 * frameMs, accuracy: 1e-9, "Block 3: speechStarted at frame 163")

        // ── AC-G7: speechStopped from Pause C at frame 230
        XCTAssertEqual(ts3, 230 * frameMs, accuracy: 1e-9, "Pause C: speechStopped at frame 230")

        // ── AC-G8: speechStarted from Block 4 at frame 295
        XCTAssertEqual(ts4, 295 * frameMs, accuracy: 1e-9, "Block 4: speechStarted at frame 295")

        // ── AC-G9: speechStopped from Pause D at frame 362
        XCTAssertEqual(ts5, 362 * frameMs, accuracy: 1e-9, "Pause D: speechStopped at frame 362")

        // ── AC-G10: speechStarted from Block 5 at frame 452
        XCTAssertEqual(ts6, 452 * frameMs, accuracy: 1e-9, "Block 5: speechStarted at frame 452")

        // ── AC-G11 (WPM proxy): gaps ≥ 2 s
        let gap1 = ts2 - ts1  // 0.896 s
        let gap2 = ts4 - ts3  // 2.080 s
        let gap3 = ts6 - ts5  // 2.880 s

        let wpmGapsCount = [gap1, gap2, gap3].filter { $0 >= 2.0 }.count
        XCTAssertEqual(wpmGapsCount, 2, "exactly 2 stop-start gaps must be ≥ 2 s (WPM close criterion)")

        // ── AC-G12 (Monologue proxy): gaps ≥ 2.5 s
        let monologueGapsCount = [gap1, gap2, gap3].filter { $0 >= 2.5 }.count
        XCTAssertEqual(monologueGapsCount, 1, "exactly 1 stop-start gap must be ≥ 2.5 s (Monologue reset criterion)")

        // ── AC-G13: gap2 is in the WPM zone but NOT the Monologue zone (key divergence)
        XCTAssertGreaterThanOrEqual(gap2, 2.0, "gap2 must be ≥ 2 s to close WPM window")
        XCTAssertLessThan(gap2, 2.5, "gap2 must be < 2.5 s — Monologue must NOT reset")
    }
}
