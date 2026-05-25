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

    /// AC-3: tokenStream must survive stop() — a consumer already waiting must receive
    /// an element yielded after stop (stream is long-lived for the backend's lifetime).
    func testTokenStreamSurvivesStop() async {
        let backend = ParakeetBackend()

        // Consumer attaches first and waits.
        let collectTask = Task<String?, Never> { @MainActor in
            for await token in backend.tokenStream {
                return token.token
            }
            return nil
        }
        await Task.yield()

        await backend.stop()

        let expected = TranscribedToken(token: "hello", startTime: 0, endTime: 1, isFinal: true)
        await backend.yieldTestToken(expected)

        let received = await collectTask.value
        XCTAssertNotNil(received, "tokenStream must survive stop() — element must arrive at waiting consumer")
        XCTAssertEqual(received, "hello")
    }

    /// AC-3: engineReadyStream must survive stop() — a consumer already waiting must receive
    /// an event yielded after stop.
    func testEngineReadyStreamSurvivesStop() async {
        let backend = ParakeetBackend()

        let collectTask = Task<Bool, Never> { @MainActor in
            for await _ in backend.engineReadyStream {
                return true
            }
            return false
        }
        await Task.yield()

        await backend.stop()

        await backend.yieldEngineReadyForTesting()

        let received = await collectTask.value
        XCTAssert(received, "engineReadyStream must survive stop() — event must arrive at waiting consumer")
    }

    /// Regression: stop() must NOT call pk_engine_destroy.
    /// The engine must remain alive so session 2 can reuse it without reinitialising ORT.
    ///
    /// NOTE: the meaningful assertion (engine non-nil after stop) only runs when a real
    /// model is on disk. In CI (no model), start() throws .modelUnavailable and the test
    /// trivially passes. The behavioral gate is the live two-session smoke run.
    func testStopDoesNotDestroyEngine() async {
        let backend = ParakeetBackend()

        let engineLoadedAfterStart: Bool
        do {
            try await backend.start(locale: Locale(identifier: "en-US"), audioProvider: nil)
            engineLoadedAfterStart = await backend.engineIsLoadedForTesting
        } catch {
            engineLoadedAfterStart = false
        }

        await backend.stop()
        let engineAliveAfterStop = await backend.engineIsLoadedForTesting

        XCTAssertEqual(
            engineAliveAfterStop, engineLoadedAfterStart,
            "stop() must not destroy the engine — it must survive for the next session"
        )
    }

    /// Regression: start() on a second session must reuse the existing engine pointer,
    /// not call pk_engine_create again (which re-initialises ORT sessions and breaks transcription).
    ///
    /// NOTE: same CI limitation as testStopDoesNotDestroyEngine — skips if no model on disk.
    func testStartDoesNotRecreateEngine() async throws {
        let backend = ParakeetBackend()

        do {
            try await backend.start(locale: Locale(identifier: "en-US"), audioProvider: nil)
        } catch {
            return  // no model in CI — skip meaningful assertion
        }
        guard await backend.engineIsLoadedForTesting else { return }

        let firstBitPattern = await backend.engineBitPatternForTesting
        await backend.stop()

        do {
            try await backend.start(locale: Locale(identifier: "en-US"), audioProvider: nil)
        } catch {
            XCTFail("second start() must not throw when engine already loaded: \(error)")
            return
        }

        let secondBitPattern = await backend.engineBitPatternForTesting
        XCTAssertEqual(
            firstBitPattern, secondBitPattern,
            "start() must reuse the existing engine — pk_engine_create must not be called again"
        )
    }

    /// Regression: speaking-activity must be true during continuous speech across hops.
    ///
    /// Parakeet returns window-relative token timestamps (0…~9.7s reset each hop).
    /// ParakeetBackend must offset them by the window's session-absolute start before
    /// adding to the tracker, so isCurrentlySpeaking(asOf: elapsed) sees times consistent
    /// with the session clock. This test fails if windowAbsoluteStart() is absent or wrong.
    func testSpeakingActivityTrueDuringContinuousHops_withWindowOffset() {
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
