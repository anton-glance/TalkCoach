import Foundation
import OSLog
import SwiftData

@ModelActor
actor SessionStore {

    func save(_ record: SessionRecord) throws {
        let session = Session(
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            language: record.language,
            userLabel: record.userLabel,
            totalWords: record.totalWords,
            averageWPM: record.averageWPM,
            peakWPM: record.peakWPM,
            wpmStandardDeviation: record.wpmStandardDeviation,
            effectiveSpeakingDuration: record.effectiveSpeakingDuration,
            wpmSamples: record.wpmSamples.map {
                WPMSample(timestamp: $0.timestamp, wpm: $0.wpm)
            },
            fillerCounts: record.fillerCounts.map {
                FillerCount(word: $0.word, count: $0.count, language: $0.language)
            },
            repeatedPhrases: record.repeatedPhrases.map {
                RepeatedPhrase(phrase: $0.phrase, count: $0.count)
            }
        )
        modelContext.insert(session)
        try modelContext.save()
    }

    func fetchAll() throws -> [SessionRecord] {
        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { toRecord($0) }
    }

    func fetchByDateRange(from startDate: Date, to endDate: Date) throws -> [SessionRecord] {
        let predicate = #Predicate<Session> {
            $0.startedAt >= startDate && $0.startedAt < endDate
        }
        let descriptor = FetchDescriptor<Session>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { toRecord($0) }
    }

    func delete(id: PersistentIdentifier) throws {
        guard let session = modelContext.model(for: id) as? Session else { return }
        modelContext.delete(session)
        try modelContext.save()
    }

    private func toRecord(_ session: Session) -> SessionRecord {
        var record = SessionRecord(
            id: session.id,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            language: session.language,
            userLabel: session.userLabel,
            totalWords: session.totalWords,
            averageWPM: session.averageWPM,
            peakWPM: session.peakWPM,
            wpmStandardDeviation: session.wpmStandardDeviation,
            effectiveSpeakingDuration: session.effectiveSpeakingDuration,
            wpmSamples: session.wpmSamples.map {
                WPMSampleRecord(timestamp: $0.timestamp, wpm: $0.wpm)
            },
            fillerCounts: session.fillerCounts.map {
                FillerCountRecord(word: $0.word, count: $0.count, language: $0.language)
            },
            repeatedPhrases: session.repeatedPhrases.map {
                RepeatedPhraseRecord(phrase: $0.phrase, count: $0.count)
            }
        )
        record.persistentModelID = session.persistentModelID
        return record
    }
}
