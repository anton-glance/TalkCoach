import XCTest
@testable import TalkCoach

@MainActor final class WhisperCppBackendTests: XCTestCase {

    // BPE tokens with a leading space start a new word; tokens without continue the current word.
    // " hello" + "world" → one word "helloworld"
    // " hello" + "world" + " there" → ["helloworld", "there"]
    func testBpeMergingProducesWordTokens() {
        let rawTokens: [RawWhisperToken] = [
            RawWhisperToken(text: " hello", t0Cs: 0,  t1Cs: 5,  prob: 0.9),
            RawWhisperToken(text: "world",  t0Cs: 5,  t1Cs: 10, prob: 0.8),
            RawWhisperToken(text: " there", t0Cs: 10, t1Cs: 15, prob: 0.95),
        ]
        let merged = WhisperCppBackend.mergeBpeTokens(rawTokens, audioSamplePositionMs: 0)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].token, "helloworld")
        XCTAssertEqual(merged[1].token, "there")
    }

    // startTime = (audioSamplePositionMs + t0_cs * 10) / 1000.0
    // audioSamplePositionMs=2000, t0_cs=5 → (2000 + 50) / 1000.0 = 2.05 s
    func testSessionOffsetTimingAccumulates() {
        let rawTokens: [RawWhisperToken] = [
            RawWhisperToken(text: " hi", t0Cs: 5, t1Cs: 10, prob: 0.9),
        ]
        let merged = WhisperCppBackend.mergeBpeTokens(rawTokens, audioSamplePositionMs: 2000)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].startTime, 2.05, accuracy: 0.001)
        XCTAssertEqual(merged[0].endTime, 2.10, accuracy: 0.001)
    }

    // Whisper special/control tokens must be detected and filtered before merging.
    func testSpecialTokenFilterDropsExpectedTokens() {
        XCTAssertTrue(WhisperCppBackend.isSpecialToken("[_BEG_]"))
        XCTAssertTrue(WhisperCppBackend.isSpecialToken("[_TT_000]"))
        XCTAssertTrue(WhisperCppBackend.isSpecialToken("<|en|>"))
        XCTAssertTrue(WhisperCppBackend.isSpecialToken("<|notimestamps|>"))
        XCTAssertFalse(WhisperCppBackend.isSpecialToken(" hello"))
        XCTAssertFalse(WhisperCppBackend.isSpecialToken("world"))
    }

    // Words whose average token probability falls below confidenceThreshold are dropped.
    // High-confidence words must be preserved and carry their confidence value.
    func testConfidenceFilterDropsLowConfidenceWords() {
        let lowConf: [RawWhisperToken] = [
            RawWhisperToken(text: " um", t0Cs: 0, t1Cs: 5, prob: 0.1),
        ]
        let highConf: [RawWhisperToken] = [
            RawWhisperToken(text: " hello", t0Cs: 0, t1Cs: 5, prob: 0.9),
        ]
        let lowResult  = WhisperCppBackend.mergeBpeTokens(lowConf,  audioSamplePositionMs: 0)
        let highResult = WhisperCppBackend.mergeBpeTokens(highConf, audioSamplePositionMs: 0)
        XCTAssertTrue(lowResult.isEmpty, "word with prob 0.1 should be dropped")
        XCTAssertFalse(highResult.isEmpty, "word with prob 0.9 should be kept")
        if !highResult.isEmpty {
            XCTAssertNotNil(highResult[0].confidence)
            XCTAssertGreaterThanOrEqual(highResult[0].confidence!, WhisperCppBackend.confidenceThreshold)
        }
    }

    // On GPU context init failure, metalFailureCount increments and CPU is retried.
    // With a nonexistent model, both GPU and CPU fail → throws modelUnavailable.
    func testMetalRetryFallsBackToCpu() async {
        let backend = WhisperCppBackend(
            whisperModelPath: "/tmp/nonexistent-talkcoach-metal-test.bin",
            sileroModelPath:  "/tmp/nonexistent-talkcoach-vad-test.bin"
        )
        do {
            try await backend.start(locale: Locale(identifier: "en"))
            XCTFail("Expected modelUnavailable to be thrown")
        } catch TranscriberBackendError.modelUnavailable {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let count = await backend.metalFailureCount
        XCTAssertEqual(count, 1, "metalFailureCount must be 1 after one GPU init failure")
    }

    // metalFailureCount resets to 0 at the start of each new session so the GPU is
    // always retried (transient macOS 26 beta Metal condition, not permanently locked to CPU).
    func testNewSessionReattemptsGpuAfterPriorCpuFallback() async {
        let backend = WhisperCppBackend(
            whisperModelPath: "/tmp/nonexistent-talkcoach-retry-test.bin",
            sileroModelPath:  "/tmp/nonexistent-talkcoach-vad-retry-test.bin"
        )
        // First session — GPU fails
        do { try await backend.start(locale: Locale(identifier: "en")) } catch {}
        await backend.stop()

        // Second session — metalFailureCount must reset to 0 before GPU is retried,
        // ending at 1 (not 2) after another GPU failure.
        do { try await backend.start(locale: Locale(identifier: "en")) } catch {}
        let count = await backend.metalFailureCount
        XCTAssertEqual(count, 1, "metalFailureCount must reset before each session start")
    }
}
