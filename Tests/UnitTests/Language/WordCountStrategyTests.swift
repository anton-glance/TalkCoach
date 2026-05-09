import XCTest
@testable import TalkCoach

@MainActor
final class WordCountStrategyTests: XCTestCase {

    private let enUS = Locale(identifier: "en_US")
    private let ruRU = Locale(identifier: "ru_RU")

    private func makeWords(_ count: Int) -> String {
        (0..<count).map { "word\($0)" }.joined(separator: " ")
    }

    private func makeSUT(wordCount: Int) -> LanguageDetector {
        let provider = FakePartialTranscriptProvider()
        provider.scriptedPartials = [makeWords(wordCount)]

        return LanguageDetector(
            declaredLocales: [enUS, ruRU],
            partialTranscriptProvider: provider,
            whisperLIDProvider: StubWhisperLIDProvider(),
            audioBufferProvider: FakeAudioBufferProvider()
        )
    }

    // MARK: - Boundary tests at t=13

    func testSwapFiresWhenWordCountIs12() async throws {
        let sut = makeSUT(wordCount: 12)
        let initial = try await sut.start()
        XCTAssertEqual(initial.identifier, "en_US")

        let expectation = XCTestExpectation(description: "swap fires for 12 words")
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
        XCTAssertEqual(swappedLocale?.identifier, "ru_RU")
    }

    func testNoSwapWhenWordCountIs13() async throws {
        let sut = makeSUT(wordCount: 13)
        let initial = try await sut.start()
        XCTAssertEqual(initial.identifier, "en_US")

        let expectation = XCTestExpectation(description: "no swap for 13 words")
        var received: [Locale] = []
        let stream = sut.localeChange
        Task { @MainActor in
            for await locale in stream {
                received.append(locale)
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 8.0)
        XCTAssertTrue(received.isEmpty, "No swap at threshold boundary (13 words >= t=13)")
    }

    func testNoSwapWhenWordCountIs14() async throws {
        let sut = makeSUT(wordCount: 14)
        let initial = try await sut.start()
        XCTAssertEqual(initial.identifier, "en_US")

        let expectation = XCTestExpectation(description: "no swap for 14 words")
        var received: [Locale] = []
        let stream = sut.localeChange
        Task { @MainActor in
            for await locale in stream {
                received.append(locale)
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 8.0)
        XCTAssertTrue(received.isEmpty, "No swap above threshold (14 words > t=13)")
    }

    func testSwapFiresOnZeroWords() async throws {
        let sut = makeSUT(wordCount: 0)
        let initial = try await sut.start()
        XCTAssertEqual(initial.identifier, "en_US")

        let expectation = XCTestExpectation(description: "swap fires for 0 words")
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
        XCTAssertEqual(swappedLocale?.identifier, "ru_RU")
    }

    // MARK: - Timeout

    func testTimesOutOnEmptyProvider() async throws {
        let provider = FakePartialTranscriptProvider()

        let sut = LanguageDetector(
            declaredLocales: [enUS, ruRU],
            partialTranscriptProvider: provider,
            whisperLIDProvider: StubWhisperLIDProvider(),
            audioBufferProvider: FakeAudioBufferProvider()
        )

        let initial = try await sut.start()
        XCTAssertEqual(initial.identifier, "en_US")

        let expectation = XCTestExpectation(description: "no hang on empty provider")
        var received: [Locale] = []
        let stream = sut.localeChange
        Task { @MainActor in
            for await locale in stream {
                received.append(locale)
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 8.0)
        XCTAssertTrue(received.isEmpty)
    }
}
