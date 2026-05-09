import AVFAudio
import XCTest
@testable import TalkCoach

@MainActor
final class WhisperLIDStrategyTests: XCTestCase {

    private let enUS = Locale(identifier: "en_US")
    private let jaJP = Locale(identifier: "ja_JP")

    private func makeSyntheticBuffer(
        sampleTime: Int64 = 0,
        frameCount: AVAudioFrameCount = 4800,
        sampleRate: Double = 48000
    ) -> CapturedAudioBuffer {
        CapturedAudioBuffer(
            frameLength: frameCount,
            sampleRate: sampleRate,
            channelCount: 1,
            sampleTime: sampleTime,
            hostTime: 0,
            samples: [Array(repeating: Float(0.1), count: Int(frameCount))]
        )
    }

    // MARK: - Strategy 3 commit

    func testCommitsDetectedLocale() async throws {
        let whisper = FakeWhisperLIDProvider()
        whisper.stubbedLocale = jaJP

        let audio = FakeAudioBufferProvider()
        audio.scriptedBuffers = (0..<30).map {
            makeSyntheticBuffer(sampleTime: Int64($0) * 4800)
        }

        let sut = LanguageDetector(
            declaredLocales: [enUS, jaJP],
            partialTranscriptProvider: StubPartialTranscriptProvider(),
            whisperLIDProvider: whisper,
            audioBufferProvider: audio
        )

        let locale = try await sut.start()
        XCTAssertEqual(locale.identifier, "ja_JP")
    }

    // MARK: - Graceful degrade

    func testGracefulDegradeOnModelUnavailable() async throws {
        let whisper = FakeWhisperLIDProvider()
        whisper.stubbedError = WhisperLIDProviderError.modelUnavailable

        let audio = FakeAudioBufferProvider()
        audio.scriptedBuffers = (0..<30).map {
            makeSyntheticBuffer(sampleTime: Int64($0) * 4800)
        }

        let sut = LanguageDetector(
            declaredLocales: [enUS, jaJP],
            partialTranscriptProvider: StubPartialTranscriptProvider(),
            whisperLIDProvider: whisper,
            audioBufferProvider: audio
        )

        let locale = try await sut.start()
        XCTAssertEqual(locale.identifier, "en_US", "Should fall back to declaredLocales[0]")
    }

    func testGracefulDegradeDoesNotThrow() async {
        let whisper = FakeWhisperLIDProvider()
        whisper.stubbedError = WhisperLIDProviderError.modelUnavailable

        let audio = FakeAudioBufferProvider()
        audio.scriptedBuffers = [makeSyntheticBuffer()]

        let sut = LanguageDetector(
            declaredLocales: [enUS, jaJP],
            partialTranscriptProvider: StubPartialTranscriptProvider(),
            whisperLIDProvider: whisper,
            audioBufferProvider: audio
        )

        do {
            _ = try await sut.start()
        } catch {
            XCTFail("start() should not throw on modelUnavailable: \(error)")
        }
    }

    // MARK: - localeChange lifecycle

    func testLocaleChangeFinishesImmediately() async throws {
        let whisper = FakeWhisperLIDProvider()
        whisper.stubbedLocale = jaJP

        let audio = FakeAudioBufferProvider()
        audio.scriptedBuffers = (0..<30).map {
            makeSyntheticBuffer(sampleTime: Int64($0) * 4800)
        }

        let sut = LanguageDetector(
            declaredLocales: [enUS, jaJP],
            partialTranscriptProvider: StubPartialTranscriptProvider(),
            whisperLIDProvider: whisper,
            audioBufferProvider: audio
        )

        _ = try await sut.start()

        let expectation = XCTestExpectation(description: "localeChange finishes")
        var received: [Locale] = []
        let stream = sut.localeChange
        Task { @MainActor in
            for await locale in stream {
                received.append(locale)
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertTrue(received.isEmpty, "Strategy 3 never emits swap — locale is committed")
    }

    // MARK: - Audio provider usage

    func testBuffersAudioFromProvider() async throws {
        let whisper = FakeWhisperLIDProvider()
        whisper.stubbedLocale = jaJP

        let audio = FakeAudioBufferProvider()
        audio.scriptedBuffers = (0..<30).map {
            makeSyntheticBuffer(sampleTime: Int64($0) * 4800)
        }

        let sut = LanguageDetector(
            declaredLocales: [enUS, jaJP],
            partialTranscriptProvider: StubPartialTranscriptProvider(),
            whisperLIDProvider: whisper,
            audioBufferProvider: audio
        )

        _ = try await sut.start()
        XCTAssertTrue(audio.callCount > 0, "Strategy 3 should consume audio buffers")
        XCTAssertTrue(whisper.callCount > 0, "Strategy 3 should call whisper provider")
    }
}
