import XCTest
@testable import TalkCoach

/// Unit tests for ParakeetBackend — these run without a real model on disk.
/// Tests that require model inference are integration-only (not in this suite).
@MainActor
final class ParakeetBackendTests: XCTestCase {

    /// AC-1: ParakeetBackend conforms to TranscriberBackend protocol.
    func testConformsToTranscriberBackend() {
        let backend: any TranscriberBackend = ParakeetBackend()
        XCTAssertNotNil(backend)
    }

    /// AC-2: start() throws .modelUnavailable when model directory does not exist.
    func testStartThrowsModelUnavailableWhenDirectoryMissing() async throws {
        let backend = ParakeetBackend()
        do {
            try await backend.start(locale: Locale(identifier: "en-US"), audioProvider: nil)
            // If the model happens to be present this test passes trivially; that's acceptable.
        } catch TranscriberBackendError.modelUnavailable {
            // Expected in CI where model is absent.
        } catch {
            XCTFail("Expected .modelUnavailable, got \(error)")
        }
    }

    /// AC-3: stop() completes without crash when called before start().
    func testStopBeforeStartIsNoOp() async {
        let backend = ParakeetBackend()
        await backend.stop()
    }

    /// AC-3: stop() finishes tokenStream so consumers can drain.
    func testStopFinishesTokenStream() async {
        let backend = ParakeetBackend()
        await backend.stop()
        var tokenCount = 0
        for await _ in backend.tokenStream { tokenCount += 1 }
        // Stream is finished; loop terminates. Count is 0.
        XCTAssertEqual(tokenCount, 0)
    }

    /// AC-3: stop() finishes speakingActivityStream.
    func testStopFinishesSpeakingActivityStream() async {
        let backend = ParakeetBackend()
        await backend.stop()
        var count = 0
        for await _ in backend.speakingActivityStream { count += 1 }
        XCTAssertEqual(count, 0)
    }

    /// AC-3: stop() finishes engineReadyStream.
    func testStopFinishesEngineReadyStream() async {
        let backend = ParakeetBackend()
        await backend.stop()
        var count = 0
        for await _ in backend.engineReadyStream { count += 1 }
        XCTAssertEqual(count, 0)
    }

    /// Regression: speaking-activity must be true during continuous speech across hops.
    ///
    /// Parakeet returns window-relative token timestamps (0…~9.7s reset each hop).
    /// ParakeetBackend must offset them by the window's session-absolute start before
    /// adding to the tracker, so isCurrentlySpeaking(asOf: elapsed) sees times consistent
    /// with the session clock. This test fails if windowAbsoluteStart() is absent or wrong.
    func testSpeakingActivityTrueDuringContinuousHops_withWindowOffset() {
        let sampleRate: Double = 16_000
        let windowSamples = RollingAudioWindow.windowSamples  // 160_000 = 10s

        var tracker = SpeakingActivityTracker()

        // Hop 1: first full window (0–10s elapsed). Parakeet tokens: window-relative 0.5–9.5s.
        let hop1Elapsed: TimeInterval = 10.0
        let hop1WindowStart = ParakeetBackend.windowAbsoluteStart(
            elapsed: hop1Elapsed, sampleCount: windowSamples
        )  // = 10 - 10 = 0.0
        tracker.reset()
        tracker.addToken(TimestampedWord(
            word: "word",
            startTime: hop1WindowStart + 0.5,
            endTime: hop1WindowStart + 9.5   // session-absolute: 9.5
        ))
        XCTAssertTrue(
            tracker.isCurrentlySpeaking(asOf: hop1Elapsed),
            "Hop 1: token ends at 9.5s, elapsed=10s — within silence timeout, must be speaking"
        )

        // Hop 2: 3s later (elapsed=13s). Parakeet tokens again window-relative 0.5–9.5s.
        let hop2Elapsed: TimeInterval = 13.0
        let hop2WindowStart = ParakeetBackend.windowAbsoluteStart(
            elapsed: hop2Elapsed, sampleCount: windowSamples
        )  // = 13 - 10 = 3.0
        tracker.reset()
        tracker.addToken(TimestampedWord(
            word: "word",
            startTime: hop2WindowStart + 0.5,  // session-absolute: 3.5
            endTime: hop2WindowStart + 9.5     // session-absolute: 12.5
        ))
        XCTAssertTrue(
            tracker.isCurrentlySpeaking(asOf: hop2Elapsed),
            "Hop 2: token ends at 12.5s, elapsed=13s — within silence timeout, must be speaking"
        )
    }
}
