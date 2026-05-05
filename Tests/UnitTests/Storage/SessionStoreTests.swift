import XCTest
import SwiftData
@testable import TalkCoach

private func makeTestStore() throws -> SessionStore {
    let schema = Schema(versionedSchema: SchemaV1.self)
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(
        for: schema,
        migrationPlan: SessionMigrationPlan.self,
        configurations: config
    )
    return SessionStore(modelContainer: container)
}

private func makeSampleRecord(
    startedAt: Date = Date(timeIntervalSince1970: 1_000_000),
    endedAt: Date = Date(timeIntervalSince1970: 1_000_300),
    language: String = "en_US",
    userLabel: String? = nil,
    totalWords: Int = 200,
    averageWPM: Double = 145.5,
    peakWPM: Double = 190.0,
    wpmStandardDeviation: Double = 12.3,
    effectiveSpeakingDuration: TimeInterval = 240.0,
    wpmSamples: [WPMSampleRecord] = [],
    fillerCounts: [FillerCountRecord] = [],
    repeatedPhrases: [RepeatedPhraseRecord] = []
) -> SessionRecord {
    SessionRecord(
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

final class SessionStoreTests: XCTestCase {

    // MARK: - Empty store

    func testEmptyStoreFetchAllReturnsEmpty() async throws {
        let store = try makeTestStore()
        let results = try await store.fetchAll()
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - Scalar field persistence

    func testSaveSessionPersistsAllScalarFields() async throws {
        let store = try makeTestStore()
        let record = makeSampleRecord(
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

        try await store.save(record)
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
        let samples = (0..<5).map { index in
            WPMSampleRecord(
                timestamp: Date(timeIntervalSince1970: Double(1_700_000_000 + index * 3)),
                wpm: 130.0 + Double(index) * 5.0
            )
        }
        let record = makeSampleRecord(wpmSamples: samples)

        try await store.save(record)
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
            FillerCountRecord(word: "um", count: 3, language: "en_US"),
            FillerCountRecord(word: "ну", count: 2, language: "ru_RU")
        ]
        let record = makeSampleRecord(fillerCounts: fillers)

        try await store.save(record)
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
            RepeatedPhraseRecord(phrase: "I think", count: 4),
            RepeatedPhraseRecord(phrase: "you know", count: 2)
        ]
        let record = makeSampleRecord(repeatedPhrases: phrases)

        try await store.save(record)
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
            WPMSampleRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_000), wpm: 130.0),
            WPMSampleRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_003), wpm: 145.0),
            WPMSampleRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_006), wpm: 160.0),
            WPMSampleRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_009), wpm: 155.0),
            WPMSampleRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_012), wpm: 140.0)
        ]
        let fillers = [
            FillerCountRecord(word: "um", count: 5, language: "en_US"),
            FillerCountRecord(word: "like", count: 3, language: "en_US"),
            FillerCountRecord(word: "ну", count: 2, language: "ru_RU")
        ]
        let phrases = [
            RepeatedPhraseRecord(phrase: "I think", count: 3),
            RepeatedPhraseRecord(phrase: "sort of", count: 2)
        ]
        let record = makeSampleRecord(
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

        try await store.save(record)
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

        try await store.save(makeSampleRecord(startedAt: yesterday))
        try await store.save(makeSampleRecord(startedAt: today))
        try await store.save(makeSampleRecord(startedAt: tomorrow))

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

        try await store.save(makeSampleRecord(startedAt: morning))
        try await store.save(makeSampleRecord(startedAt: afternoon))
        try await store.save(makeSampleRecord(startedAt: evening))

        let rangeStart = Date(timeIntervalSince1970: 1_700_043_200) // ~12pm
        let rangeEnd = Date(timeIntervalSince1970: 1_700_061_200)   // ~5pm

        let fetched = try await store.fetchByDateRange(from: rangeStart, to: rangeEnd)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].startedAt, afternoon)
    }

    func testFetchByDateRangeIsInclusiveOfFromBoundary() async throws {
        let store = try makeTestStore()
        let exact = Date(timeIntervalSince1970: 1_700_050_400)
        try await store.save(makeSampleRecord(startedAt: exact))

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
        try await store.save(makeSampleRecord())

        let before = try await store.fetchAll()
        XCTAssertEqual(before.count, 1)

        let idToDelete = try XCTUnwrap(before[0].persistentModelID)
        try await store.delete(id: idToDelete)

        let after = try await store.fetchAll()
        XCTAssertEqual(after.count, 0)
    }

    // MARK: - Optional fields

    func testUserLabelOptionalCanBeNil() async throws {
        let store = try makeTestStore()
        try await store.save(makeSampleRecord(userLabel: nil))

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
        let session = Session(
            startedAt: .now,
            endedAt: .now,
            language: "en_US",
            totalWords: 0,
            averageWPM: 0,
            peakWPM: 0,
            wpmStandardDeviation: 0,
            effectiveSpeakingDuration: 0
        )
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

    func testNoTranscriptFieldOnAnyRecordType() {
        let forbiddenNames: Set<String> = [
            "text", "transcript", "transcription", "utterance", "content"
        ]

        let instances: [(String, Any)] = [
            ("SessionRecord", makeSampleRecord()),
            ("WPMSampleRecord", WPMSampleRecord(timestamp: .now, wpm: 0)),
            ("FillerCountRecord", FillerCountRecord(word: "", count: 0, language: "")),
            ("RepeatedPhraseRecord", RepeatedPhraseRecord(phrase: "", count: 0))
        ]

        var allViolations: [String] = []
        for (typeName, instance) in instances {
            let mirror = Mirror(reflecting: instance)
            let names = mirror.children.compactMap { $0.label }
            let hits = names.filter { forbiddenNames.contains($0.lowercased()) }
            for hit in hits {
                allViolations.append("\(typeName).\(hit)")
            }
        }

        XCTAssertEqual(
            allViolations, [],
            "Record types must not contain transcript-like fields, but found: \(allViolations)"
        )
    }
}
