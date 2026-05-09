import XCTest
@testable import TalkCoach

// MARK: - Fake Providers

final class FakePartialTranscriptProvider: PartialTranscriptProvider, @unchecked Sendable {
    nonisolated(unsafe) var scriptedPartials: [String] = []
    nonisolated(unsafe) var callCount = 0

    func partialTranscriptStream() -> AsyncStream<String> {
        callCount += 1
        let partials = scriptedPartials
        return AsyncStream { continuation in
            for partial in partials {
                continuation.yield(partial)
            }
            continuation.finish()
        }
    }
}

final class FakeWhisperLIDProvider: WhisperLIDProvider, @unchecked Sendable {
    nonisolated(unsafe) var stubbedLocale: Locale?
    nonisolated(unsafe) var stubbedError: Error?
    nonisolated(unsafe) var callCount = 0
    nonisolated(unsafe) var receivedLocales: [Locale] = []

    func detectLanguage(
        from buffers: [CapturedAudioBuffer],
        constrainedTo locales: [Locale]
    ) async throws -> Locale {
        callCount += 1
        receivedLocales = locales
        if let error = stubbedError { throw error }
        return stubbedLocale!
    }
}

final class FakeAudioBufferProvider: AudioBufferProvider, @unchecked Sendable {
    nonisolated(unsafe) var scriptedBuffers: [CapturedAudioBuffer] = []
    nonisolated(unsafe) var callCount = 0

    func bufferStream() -> AsyncStream<CapturedAudioBuffer> {
        callCount += 1
        let buffers = scriptedBuffers
        return AsyncStream { continuation in
            for buffer in buffers {
                continuation.yield(buffer)
            }
            continuation.finish()
        }
    }
}

// MARK: - Strategy dispatch tests

@MainActor
final class LanguageDetectorTests: XCTestCase {

    private func makeProviders() -> (
        FakePartialTranscriptProvider,
        FakeWhisperLIDProvider,
        FakeAudioBufferProvider
    ) {
        let partial = FakePartialTranscriptProvider()
        let whisper = FakeWhisperLIDProvider()
        whisper.stubbedError = WhisperLIDProviderError.modelUnavailable
        let audio = FakeAudioBufferProvider()
        return (partial, whisper, audio)
    }

    private func makeSUT(
        locales: [String],
        partial: FakePartialTranscriptProvider? = nil,
        whisper: FakeWhisperLIDProvider? = nil,
        audio: FakeAudioBufferProvider? = nil
    ) -> LanguageDetector {
        let (defaultPartial, defaultWhisper, defaultAudio) = makeProviders()
        return LanguageDetector(
            declaredLocales: locales.map { Locale(identifier: $0) },
            partialTranscriptProvider: partial ?? defaultPartial,
            whisperLIDProvider: whisper ?? defaultWhisper,
            audioBufferProvider: audio ?? defaultAudio
        )
    }

    // MARK: - Strategy dispatch

    func testSingleLocaleRoutesToSingleLocaleStrategy() async throws {
        let sut = makeSUT(locales: ["en_US"])
        let locale = try await sut.start()
        XCTAssertEqual(locale.identifier, "en_US")
    }

    func testEnEsRoutesToSameScriptStrategy() async throws {
        let partial = FakePartialTranscriptProvider()
        partial.scriptedPartials = Array(repeating: "hello world testing speech", count: 5)
        let sut = makeSUT(locales: ["en_US", "es_ES"], partial: partial)
        let locale = try await sut.start()
        XCTAssertEqual(locale.identifier, "en_US")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(partial.callCount > 0, "SameScriptStrategy should call PartialTranscriptProvider")
    }

    func testEnRuRoutesToWordCountStrategy() async throws {
        let partial = FakePartialTranscriptProvider()
        partial.scriptedPartials = Array(repeating: "hello world testing speech", count: 5)
        let sut = makeSUT(locales: ["en_US", "ru_RU"], partial: partial)
        let locale = try await sut.start()
        XCTAssertEqual(locale.identifier, "en_US")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(partial.callCount > 0, "WordCountStrategy should call PartialTranscriptProvider")
    }

    func testEnJaRoutesToWhisperLIDStrategy() async throws {
        let whisper = FakeWhisperLIDProvider()
        whisper.stubbedError = WhisperLIDProviderError.modelUnavailable
        let audio = FakeAudioBufferProvider()
        let sut = makeSUT(locales: ["en_US", "ja_JP"], whisper: whisper, audio: audio)
        let locale = try await sut.start()
        XCTAssertEqual(locale.identifier, "en_US")
    }

    func testEnKoRoutesToWhisperLIDStrategy() async throws {
        let whisper = FakeWhisperLIDProvider()
        whisper.stubbedError = WhisperLIDProviderError.modelUnavailable
        let audio = FakeAudioBufferProvider()
        let sut = makeSUT(locales: ["en_US", "ko_KR"], whisper: whisper, audio: audio)
        let locale = try await sut.start()
        XCTAssertEqual(locale.identifier, "en_US")
    }

    func testEnZhRoutesToWhisperLIDStrategy() async throws {
        let whisper = FakeWhisperLIDProvider()
        whisper.stubbedError = WhisperLIDProviderError.modelUnavailable
        let audio = FakeAudioBufferProvider()
        let sut = makeSUT(locales: ["en_US", "zh_CN"], whisper: whisper, audio: audio)
        let locale = try await sut.start()
        XCTAssertEqual(locale.identifier, "en_US")
    }

    func testEnArRoutesToWordCountStrategy() async throws {
        let partial = FakePartialTranscriptProvider()
        partial.scriptedPartials = Array(repeating: "hello world testing speech", count: 5)
        let sut = makeSUT(locales: ["en_US", "ar_SA"], partial: partial)
        let locale = try await sut.start()
        XCTAssertEqual(locale.identifier, "en_US")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(partial.callCount > 0, "WordCountStrategy should call PartialTranscriptProvider for EN+AR")
    }

    func testEnHiRoutesToWordCountStrategy() async throws {
        let partial = FakePartialTranscriptProvider()
        partial.scriptedPartials = Array(repeating: "hello world testing speech", count: 5)
        let sut = makeSUT(locales: ["en_US", "hi_IN"], partial: partial)
        let locale = try await sut.start()
        XCTAssertEqual(locale.identifier, "en_US")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(partial.callCount > 0, "WordCountStrategy should call PartialTranscriptProvider for EN+HI")
    }

    func testEnFrRoutesToSameScriptStrategy() async throws {
        let partial = FakePartialTranscriptProvider()
        partial.scriptedPartials = Array(repeating: "hello world testing speech", count: 5)
        let sut = makeSUT(locales: ["en_US", "fr_FR"], partial: partial)
        let locale = try await sut.start()
        XCTAssertEqual(locale.identifier, "en_US")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(partial.callCount > 0, "SameScriptStrategy should call PartialTranscriptProvider for EN+FR")
    }

    func testRuJaRoutesToWhisperLIDStrategy() async throws {
        let whisper = FakeWhisperLIDProvider()
        whisper.stubbedError = WhisperLIDProviderError.modelUnavailable
        let audio = FakeAudioBufferProvider()
        let sut = makeSUT(locales: ["ru_RU", "ja_JP"], whisper: whisper, audio: audio)
        let locale = try await sut.start()
        XCTAssertEqual(locale.identifier, "ru_RU")
    }

    // MARK: - N=1 trivial path

    func testSingleLocaleReturnsImmediately() async throws {
        let sut = makeSUT(locales: ["en_US"])
        let locale = try await sut.start()
        XCTAssertEqual(locale.identifier, "en_US")
    }

    func testSingleLocaleFinishesLocaleChange() async throws {
        let sut = makeSUT(locales: ["en_US"])
        _ = try await sut.start()

        let expectation = XCTestExpectation(description: "localeChange finishes")
        let stream = sut.localeChange
        Task { @MainActor in
            for await _ in stream {}
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func testSingleLocaleCallsNoProviders() async throws {
        let partial = FakePartialTranscriptProvider()
        let whisper = FakeWhisperLIDProvider()
        whisper.stubbedError = WhisperLIDProviderError.modelUnavailable
        let audio = FakeAudioBufferProvider()
        let sut = makeSUT(locales: ["en_US"], partial: partial, whisper: whisper, audio: audio)
        _ = try await sut.start()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(partial.callCount, 0)
        XCTAssertEqual(whisper.callCount, 0)
        XCTAssertEqual(audio.callCount, 0)
    }

    // MARK: - Idempotency

    func testStartTwiceReturnsSameLocale() async throws {
        let sut = makeSUT(locales: ["en_US"])
        let first = try await sut.start()
        let second = try await sut.start()
        XCTAssertEqual(first.identifier, second.identifier)
    }

    func testStopTwiceIsNoOp() async throws {
        let sut = makeSUT(locales: ["en_US"])
        _ = try await sut.start()
        await sut.stop()
        await sut.stop()
    }

    func testStopBeforeStartIsNoOp() async {
        let partial = FakePartialTranscriptProvider()
        let whisper = FakeWhisperLIDProvider()
        whisper.stubbedError = WhisperLIDProviderError.modelUnavailable
        let audio = FakeAudioBufferProvider()
        let sut = makeSUT(locales: ["en_US"], partial: partial, whisper: whisper, audio: audio)
        await sut.stop()
        XCTAssertEqual(partial.callCount, 0)
        XCTAssertEqual(whisper.callCount, 0)
        XCTAssertEqual(audio.callCount, 0)
    }

    func testStopFinishesLocaleChange() async throws {
        let sut = makeSUT(locales: ["en_US", "es_ES"])
        _ = try await sut.start()
        await sut.stop()

        let expectation = XCTestExpectation(description: "localeChange finishes after stop")
        let stream = sut.localeChange
        Task { @MainActor in
            for await _ in stream {}
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2.0)
    }
}
