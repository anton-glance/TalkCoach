import Testing
@testable import Spike17_1

// Unit tests for VADHeuristic — no FluidAudio dependency, runs offline.
@Suite("VADHeuristic")
struct VADHeuristicTests {

    @Test("emits silence window when gap exceeds threshold")
    func singleSilenceWindow() {
        // gap 400ms between 100 and 500 > 300ms threshold → exactly one window
        // 500→550 gap = 50ms and trailing 550→700 = 150ms are both under threshold
        let times = [100.0, 500.0, 550.0]
        let windows = VADHeuristic.inferredSilenceWindows(
            emissionTimestamps: times,
            sessionDurationMs: 700,
            silenceThresholdMs: 300
        )
        #expect(windows.count == 1)
        // Window starts at 100 + 300 = 400ms, ends at 500ms
        #expect(abs(windows[0].start - 400.0) < 1.0)
        #expect(abs(windows[0].end - 500.0) < 1.0)
    }

    @Test("returns full session as silence when no tokens emitted")
    func noTokens() {
        let windows = VADHeuristic.inferredSilenceWindows(
            emissionTimestamps: [],
            sessionDurationMs: 5000,
            silenceThresholdMs: 300
        )
        #expect(windows.count == 1)
        #expect(windows[0].start == 0.0)
        #expect(windows[0].end == 5000.0)
    }

    @Test("trailing silence after last token is captured")
    func trailingSilence() {
        let times = [100.0, 200.0, 300.0]
        let windows = VADHeuristic.inferredSilenceWindows(
            emissionTimestamps: times,
            sessionDurationMs: 5000,
            silenceThresholdMs: 300
        )
        // No gap > 300ms between 100→200→300; trailing gap = 4700ms > 300ms
        #expect(windows.count == 1)
        #expect(abs(windows[0].start - 600.0) < 1.0)  // 300 + 300
        #expect(abs(windows[0].end - 5000.0) < 1.0)
    }

    @Test("no window emitted when all gaps within threshold")
    func denseTokens() {
        let times = stride(from: 0.0, through: 3000.0, by: 100.0).map { $0 }
        let windows = VADHeuristic.inferredSilenceWindows(
            emissionTimestamps: times,
            sessionDurationMs: 3200,
            silenceThresholdMs: 300
        )
        // All inter-token gaps = 100ms < 300ms; trailing gap = 200ms < 300ms
        #expect(windows.isEmpty)
    }
}
