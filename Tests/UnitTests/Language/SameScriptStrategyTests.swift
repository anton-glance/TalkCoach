import XCTest
@testable import TalkCoach

@MainActor
final class SameScriptStrategyTests: XCTestCase {

    private let enUS = Locale(identifier: "en_US")
    private let esES = Locale(identifier: "es_ES")

    private func makeFakeProvider(partials: [String]) -> FakePartialTranscriptProvider {
        let provider = FakePartialTranscriptProvider()
        provider.scriptedPartials = partials
        return provider
    }

    // MARK: - Swap behavior

    func testSwapFiresWhenWrongGuess() async throws {
        let spanishText = "Hola buenos dias como estas yo estoy bien gracias por preguntar"
        let provider = makeFakeProvider(partials: [spanishText])

        let sut = LanguageDetector(
            declaredLocales: [enUS, esES],
            partialTranscriptProvider: provider,
            whisperLIDProvider: StubWhisperLIDProvider(),
            audioBufferProvider: FakeAudioBufferProvider()
        )

        let initial = try await sut.start()
        XCTAssertEqual(initial.identifier, "en_US")

        let expectation = XCTestExpectation(description: "localeChange emits swap")
        var swappedLocale: Locale?
        let stream = sut.localeChange
        Task { @MainActor in
            for await locale in stream {
                swappedLocale = locale
                expectation.fulfill()
                break
            }
        }
        await fulfillment(of: [expectation], timeout: 8.0)
        XCTAssertEqual(swappedLocale?.identifier, "es_ES")
    }

    func testNoSwapWhenCorrectGuess() async throws {
        let englishText = "Hello good morning how are you I am fine thank you for asking"
        let provider = makeFakeProvider(partials: [englishText])

        let sut = LanguageDetector(
            declaredLocales: [enUS, esES],
            partialTranscriptProvider: provider,
            whisperLIDProvider: StubWhisperLIDProvider(),
            audioBufferProvider: FakeAudioBufferProvider()
        )

        let initial = try await sut.start()
        XCTAssertEqual(initial.identifier, "en_US")

        let expectation = XCTestExpectation(description: "localeChange finishes without swap")
        var received: [Locale] = []
        let stream = sut.localeChange
        Task { @MainActor in
            for await locale in stream {
                received.append(locale)
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 8.0)
        XCTAssertTrue(received.isEmpty, "No swap should fire when correct guess")
    }

    // MARK: - Timeout

    func testTimesOutOnEmptyProvider() async throws {
        let provider = FakePartialTranscriptProvider()

        let sut = LanguageDetector(
            declaredLocales: [enUS, esES],
            partialTranscriptProvider: provider,
            whisperLIDProvider: StubWhisperLIDProvider(),
            audioBufferProvider: FakeAudioBufferProvider()
        )

        let initial = try await sut.start()
        XCTAssertEqual(initial.identifier, "en_US")

        let expectation = XCTestExpectation(description: "localeChange finishes on empty provider")
        var received: [Locale] = []
        let stream = sut.localeChange
        Task { @MainActor in
            for await locale in stream {
                received.append(locale)
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 8.0)
        XCTAssertTrue(received.isEmpty, "No swap on empty provider")
    }
}
