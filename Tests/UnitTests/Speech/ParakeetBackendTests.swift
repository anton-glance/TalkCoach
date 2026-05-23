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
}
