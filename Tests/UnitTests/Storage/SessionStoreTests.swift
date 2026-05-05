import XCTest
import SwiftData
@testable import TalkCoach

final class SessionStoreTests: XCTestCase {

    private func makeTestStore() throws -> SessionStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: SchemaV1.self,
            configurations: config
        )
        return SessionStore(modelContainer: container)
    }

    private func makeSampleSession(
        startedAt: Date = Date(timeIntervalSince1970: 1_000_000),
        endedAt: Date = Date(timeIntervalSince1970: 1_000_300),
        language: String = "en_US",
        userLabel: String? = nil,
        totalWords: Int = 200,
        averageWPM: Double = 145.5,
        peakWPM: Double = 190.0,
        wpmStandardDeviation: Double = 12.3,
        effectiveSpeakingDuration: TimeInterval = 240.0,
        wpmSamples: [WPMSample] = [],
        fillerCounts: [FillerCount] = [],
        repeatedPhrases: [RepeatedPhrase] = []
    ) -> Session {
        Session(
            startedAt: startedAt,
            endedAt: endedAt,
            language: language,
            userLabel: userLabel,
            totalWords: totalWords,
            averageWPM: averageWPM,
            peakWPM: peakWPM,
            wpmStandardDeviation: wpmStandardDeviation,
            effectiveSpeakingDuration: effectiveSpeakingDuration,
            wpmSamples: wpmSamples,
            fillerCounts: fillerCounts,
            repeatedPhrases: repeatedPhrases
        )
    }

    // MARK: - Empty store

    func testEmptyStoreFetchAllReturnsEmpty() async throws {
        let store = try makeTestStore()
        let results = try await store.fetchAll()
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - Scalar field persistence

    func testSaveSessionPersistsAllScalarFields() async throws {
        let store = try makeTestStore()
        let session = makeSampleSession(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_300),
            language: "en_US",
            userLabel: "Test",
            totalWords: 200,
            averageWPM: 145.5,
            peakWPM: 190.0,
            wpmStandardDeviation: 12.3,
            effectiveSpeakingDuration: 240.0
        )

        try await store.save(session)
        let fetched = try await store.fetchAll()

        XCTAssertEqual(fetched.count, 1)
        let result = try XCTUnwrap(fetched.first)
        XCTAssertEqual(result.startedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(result.endedAt, Date(timeIntervalSince1970: 1_700_000_300))
        XCTAssertEqual(result.language, "en_US")
        XCTAssertEqual(result.userLabel, "Test")
        XCTAssertEqual(result.totalWords, 200)
        XCTAssertEqual(result.averageWPM, 145.5, accuracy: 0.001)
        XCTAssertEqual(result.peakWPM, 190.0, accuracy: 0.001)
        XCTAssertEqual(result.wpmStandardDeviation, 12.3, accuracy: 0.001)
        XCTAssertEqual(result.effectiveSpeakingDuration, 240.0, accuracy: 0.001)
    }

    // MARK: - Relationship persistence (individual)

    func testSaveSessionPersistsWPMSamples() async throws {
        let store = try makeTestStore()
        let samples = (0..<5).map { i in
            WPMSample(
                timestamp: Date(timeIntervalSince1970: Double(1_700_000_000 + i * 3)),
                wpm: 130.0 + Double(i) * 5.0
            )
        }
        let session = makeSampleSession(wpmSamples: samples)

        try await store.save(session)
        let fetched = try await store.fetchAll()
        let result = try XCTUnwrap(fetched.first)

        XCTAssertEqual(result.wpmSamples.count, 5)
        let sorted = result.wpmSamples.sorted { $0.timestamp < $1.timestamp }
        for (index, sample) in sorted.enumerated() {
            XCTAssertEqual(
                sample.timestamp,
                Date(timeIntervalSince1970: Double(1_700_000_000 + index * 3))
            )
            XCTAssertEqual(sample.wpm, 130.0 + Double(index) * 5.0, accuracy: 0.001)
        }
    }

    func testSaveSessionPersistsFillerCounts() async throws {
        let store = try makeTestStore()
        let fillers = [
            FillerCount(word: "um", count: 3, language: "en_US"),
            FillerCount(word: "ну", count: 2, language: "ru_RU")
        ]
        let session = makeSampleSession(fillerCounts: fillers)

        try await store.save(session)
        let fetched = try await store.fetchAll()
        let result = try XCTUnwrap(fetched.first)

        XCTAssertEqual(result.fillerCounts.count, 2)
        let sortedFillers = result.fillerCounts.sorted { $0.word < $1.word }
        XCTAssertEqual(sortedFillers[0].word, "um")
        XCTAssertEqual(sortedFillers[0].count, 3)
        XCTAssertEqual(sortedFillers[0].language, "en_US")
        XCTAssertEqual(sortedFillers[1].word, "ну")
        XCTAssertEqual(sortedFillers[1].count, 2)
        XCTAssertEqual(sortedFillers[1].language, "ru_RU")
    }

    func testSaveSessionPersistsRepeatedPhrases() async throws {
        let store = try makeTestStore()
        let phrases = [
            RepeatedPhrase(phrase: "I think", count: 4),
            RepeatedPhrase(phrase: "you know", count: 2)
        ]
        let session = makeSampleSession(repeatedPhrases: phrases)

        try await store.save(session)
        let fetched = try await store.fetchAll()
        let result = try XCTUnwrap(fetched.first)

        XCTAssertEqual(result.repeatedPhrases.count, 2)
        let sorted = result.repeatedPhrases.sorted { $0.phrase < $1.phrase }
        XCTAssertEqual(sorted[0].phrase, "I think")
        XCTAssertEqual(sorted[0].count, 4)
        XCTAssertEqual(sorted[1].phrase, "you know")
        XCTAssertEqual(sorted[1].count, 2)
    }

    // MARK: - Comprehensive round-trip (Correction 3, option b)

    func testSaveSessionRoundTripsWithAllRelationships() async throws {
        let store = try makeTestStore()
        let samples = [
            WPMSample(timestamp: Date(timeIntervalSince1970: 1_700_000_000), wpm: 130.0),
            WPMSample(timestamp: Date(timeIntervalSince1970: 1_700_000_003), wpm: 145.0),
            WPMSample(timestamp: Date(timeIntervalSince1970: 1_700_000_006), wpm: 160.0),
            WPMSample(timestamp: Date(timeIntervalSince1970: 1_700_000_009), wpm: 155.0),
            WPMSample(timestamp: Date(timeIntervalSince1970: 1_700_000_012), wpm: 140.0)
        ]
        let fillers = [
            FillerCount(word: "um", count: 5, language: "en_US"),
            FillerCount(word: "like", count: 3, language: "en_US"),
            FillerCount(word: "ну", count: 2, language: "ru_RU")
        ]
        let phrases = [
            RepeatedPhrase(phrase: "I think", count: 3),
            RepeatedPhrase(phrase: "sort of", count: 2)
        ]
        let session = makeSampleSession(
            language: "en_US",
            userLabel: "Full round-trip",
            totalWords: 500,
            averageWPM: 146.0,
            peakWPM: 160.0,
            wpmStandardDeviation: 10.5,
            effectiveSpeakingDuration: 205.0,
            wpmSamples: samples,
            fillerCounts: fillers,
            repeatedPhrases: phrases
        )

        try await store.save(session)
        let fetched = try await store.fetchAll()
        let result = try XCTUnwrap(fetched.first)

        XCTAssertEqual(result.totalWords, 500)
        XCTAssertEqual(result.userLabel, "Full round-trip")
        XCTAssertEqual(result.wpmSamples.count, 5)
        XCTAssertEqual(result.fillerCounts.count, 3)
        XCTAssertEqual(result.repeatedPhrases.count, 2)
    }

    // MARK: - Ordering

    func testFetchAllSortedByStartedAtDescending() async throws {
        let store = try makeTestStore()
        let yesterday = Date(timeIntervalSince1970: 1_700_000_000)
        let today = Date(timeIntervalSince1970: 1_700_086_400)
        let tomorrow = Date(timeIntervalSince1970: 1_700_172_800)

        try await store.save(makeSampleSession(startedAt: yesterday))
        try await store.save(makeSampleSession(startedAt: today))
        try await store.save(makeSampleSession(startedAt: tomorrow))

        let fetched = try await store.fetchAll()
        XCTAssertEqual(fetched.count, 3)
        XCTAssertEqual(fetched[0].startedAt, tomorrow)
        XCTAssertEqual(fetched[1].startedAt, today)
        XCTAssertEqual(fetched[2].startedAt, yesterday)
    }

    // MARK: - Date range filtering

    func testFetchByDateRangeFiltersCorrectly() async throws {
        let store = try makeTestStore()
        let morning = Date(timeIntervalSince1970: 1_700_036_000)   // ~10am
        let afternoon = Date(timeIntervalSince1970: 1_700_050_400) // ~2pm
        let evening = Date(timeIntervalSince1970: 1_700_064_800)   // ~6pm

        try await store.save(makeSampleSession(startedAt: morning))
        try await store.save(makeSampleSession(startedAt: afternoon))
        try await store.save(makeSampleSession(startedAt: evening))

        let from = Date(timeIntervalSince1970: 1_700_043_200) // ~12pm
        let to = Date(timeIntervalSince1970: 1_700_061_200)   // ~5pm

        let fetched = try await store.fetchByDateRange(from: from, to: to)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].startedAt, afternoon)
    }

    func testFetchByDateRangeIsInclusiveOfFromBoundary() async throws {
        let store = try makeTestStore()
        let exact = Date(timeIntervalSince1970: 1_700_050_400)
        try await store.save(makeSampleSession(startedAt: exact))

        // [from, to) — from is inclusive
        let fetched = try await store.fetchByDateRange(
            from: exact,
            to: Date(timeIntervalSince1970: 1_700_050_401)
        )
        XCTAssertEqual(fetched.count, 1)

        // [from, to) — to is exclusive
        let fetchedExclusive = try await store.fetchByDateRange(
            from: Date(timeIntervalSince1970: 1_700_050_399),
            to: exact
        )
        XCTAssertEqual(fetchedExclusive.count, 0)
    }

    // MARK: - Delete

    func testDeleteRemovesSession() async throws {
        let store = try makeTestStore()
        let session = makeSampleSession()
        try await store.save(session)

        let before = try await store.fetchAll()
        XCTAssertEqual(before.count, 1)

        try await store.delete(before[0])

        let after = try await store.fetchAll()
        XCTAssertEqual(after.count, 0)
    }

    // MARK: - Optional fields

    func testUserLabelOptionalCanBeNil() async throws {
        let store = try makeTestStore()
        let session = makeSampleSession(userLabel: nil)
        try await store.save(session)

        let fetched = try await store.fetchAll()
        let result = try XCTUnwrap(fetched.first)
        XCTAssertNil(result.userLabel)
    }

    // MARK: - Schema version

    func testSchemaVersionIsOneZeroZero() {
        XCTAssertEqual(
            SchemaV1.versionIdentifier,
            Schema.Version(1, 0, 0)
        )
    }

    // MARK: - No transcript fields

    func testNoTranscriptFieldOnSession() {
        let session = makeSampleSession()
        let mirror = Mirror(reflecting: session)
        let forbiddenNames: Set<String> = [
            "text", "transcript", "transcription", "utterance", "content"
        ]
        let propertyNames = mirror.children.compactMap { $0.label }
        let violations = propertyNames.filter { forbiddenNames.contains($0.lowercased()) }
        XCTAssertEqual(
            violations, [],
            "Session must not contain transcript-like fields, but found: \(violations)"
        )
    }
}
