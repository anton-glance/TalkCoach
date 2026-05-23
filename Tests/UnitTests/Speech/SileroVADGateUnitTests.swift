import XCTest
@testable import TalkCoach

// MARK: - StubFrameProcessor

/// Pre-loaded probability queue. Returned values are consumed in order; returns 0.0
/// when the queue is exhausted. Thread-safe so it can satisfy `VADFrameProcessor`'s
/// `nonisolated` contract without capturing actor state.
private final class StubFrameProcessor: VADFrameProcessor, @unchecked Sendable {
    private var queue: [Float] = []
    private let lock = NSLock()

    func enqueue(_ probabilities: [Float]) {
        lock.withLock { queue.append(contentsOf: probabilities) }
    }

    nonisolated func processFrame(_ samples: [Float]) -> Float {
        lock.withLock { queue.isEmpty ? 0.0 : queue.removeFirst() }
    }

    nonisolated func reset() {
        lock.withLock { queue.removeAll() }
    }
}

// MARK: - SileroVADGateUnitTests

@MainActor
final class SileroVADGateUnitTests: XCTestCase {

    // MARK: - Onset (RED: _updateDebounce stub does nothing → 0 starts ≠ 1)

    /// A single speech frame above threshold must immediately trigger speechStarted
    /// because onlineDebounceFrames = 1.
    func testOnsetIsImmediate() async {
        let gate = SileroVADGate(frameProcessor: StubFrameProcessor())

        let task = Task {
            var events: [VADTransitionEvent] = []
            for await e in gate.transitionStream { events.append(e) }
            return events
        }

        await gate._testProcessFrame(0.9)  // above threshold → speechStarted

        await gate.stop()
        let events = await task.value

        XCTAssertEqual(events.count, 1)
        if case .speechStarted = events.first { } else {
            XCTFail("Expected speechStarted, got \(String(describing: events.first))")
        }
    }

    // MARK: - Short silence filtered (RED: _updateDebounce stub does nothing → 0 starts ≠ 1)

    /// 20 speech → 4 silence → 20 speech should yield exactly 1 start, 0 stops.
    /// The 4-frame pause is below offlineDebounceFrames (5), so no speechStopped.
    func testDebounceFiltersShortSilence() async {
        let gate = SileroVADGate(frameProcessor: StubFrameProcessor())

        let task = Task {
            var events: [VADTransitionEvent] = []
            for await e in gate.transitionStream { events.append(e) }
            return events
        }

        for _ in 0..<20 { await gate._testProcessFrame(0.9) }
        for _ in 0..<4  { await gate._testProcessFrame(0.0) }
        for _ in 0..<20 { await gate._testProcessFrame(0.9) }

        await gate.stop()
        let events = await task.value

        let starts = events.filter { if case .speechStarted = $0 { return true }; return false }
        let stops  = events.filter { if case .speechStopped = $0 { return true }; return false }

        XCTAssertEqual(starts.count, 1, "expected 1 speechStarted")
        XCTAssertEqual(stops.count, 0,  "4-frame pause must not trigger speechStopped")
    }

    // MARK: - Long silence emits stop (RED: _updateDebounce stub does nothing → 0 stops ≠ 1)

    /// 20 speech → 6 silence (≥ offlineDebounceFrames = 5) should yield 1 start, 1 stop.
    func testDebounceEmitsTransitionOnLongSilence() async {
        let gate = SileroVADGate(frameProcessor: StubFrameProcessor())

        let task = Task {
            var events: [VADTransitionEvent] = []
            for await e in gate.transitionStream { events.append(e) }
            return events
        }

        for _ in 0..<20 { await gate._testProcessFrame(0.9) }
        for _ in 0..<6  { await gate._testProcessFrame(0.0) }

        await gate.stop()
        let events = await task.value

        let starts = events.filter { if case .speechStarted = $0 { return true }; return false }
        let stops  = events.filter { if case .speechStopped = $0 { return true }; return false }

        XCTAssertEqual(starts.count, 1, "expected 1 speechStarted")
        XCTAssertEqual(stops.count, 1,  "6-frame silence must trigger speechStopped")
    }

    // MARK: - Transition stream finishes on stop (passes in both RED and GREEN)

    func testTransitionStreamFinishesOnStop() async {
        let gate = SileroVADGate(frameProcessor: StubFrameProcessor())

        await gate.stop()

        var count = 0
        for await _ in gate.transitionStream { count += 1 }
        XCTAssertEqual(count, 0)
    }

    // MARK: - Audio-time timestamps (RED: _updateDebounce stub does nothing → no events)

    /// speechStarted timestamp must equal frame_index × 32ms (audio time, not wall clock).
    func testSpeechStartedTimestampIsAudioTime() async {
        let gate = SileroVADGate(frameProcessor: StubFrameProcessor())

        let task = Task {
            var events: [VADTransitionEvent] = []
            for await e in gate.transitionStream { events.append(e) }
            return events
        }

        // Frame 1 is the first speech frame; expected elapsed = 1 × 512 / 16000 = 0.032s
        await gate._testProcessFrame(0.9)

        await gate.stop()
        let events = await task.value

        guard case .speechStarted(let t) = events.first else {
            XCTFail("Expected speechStarted event")
            return
        }
        XCTAssertEqual(t, 0.032, accuracy: 1e-9, "timestamp must be audio-time (frame 1 × 32ms)")
    }
}
