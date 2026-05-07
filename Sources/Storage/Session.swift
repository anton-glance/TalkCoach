import Foundation
import SwiftData

// MARK: - SwiftData models (actor-isolated, never cross boundaries)

@Model
final class Session {
    var id: UUID = UUID()
    var startedAt: Date
    var endedAt: Date
    var language: String
    var userLabel: String?
    var totalWords: Int
    var averageWPM: Double
    var peakWPM: Double
    var wpmStandardDeviation: Double
    var effectiveSpeakingDuration: TimeInterval

    @Relationship(deleteRule: .cascade, inverse: \WPMSample.session)
    var wpmSamples: [WPMSample] = []

    @Relationship(deleteRule: .cascade, inverse: \FillerCount.session)
    var fillerCounts: [FillerCount] = []

    @Relationship(deleteRule: .cascade, inverse: \RepeatedPhrase.session)
    var repeatedPhrases: [RepeatedPhrase] = []

    init(
        startedAt: Date,
        endedAt: Date,
        language: String,
        userLabel: String? = nil,
        totalWords: Int,
        averageWPM: Double,
        peakWPM: Double,
        wpmStandardDeviation: Double,
        effectiveSpeakingDuration: TimeInterval,
        wpmSamples: [WPMSample] = [],
        fillerCounts: [FillerCount] = [],
        repeatedPhrases: [RepeatedPhrase] = []
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.language = language
        self.userLabel = userLabel
        self.totalWords = totalWords
        self.averageWPM = averageWPM
        self.peakWPM = peakWPM
        self.wpmStandardDeviation = wpmStandardDeviation
        self.effectiveSpeakingDuration = effectiveSpeakingDuration
        self.wpmSamples = wpmSamples
        self.fillerCounts = fillerCounts
        self.repeatedPhrases = repeatedPhrases
    }
}

@Model
final class WPMSample {
    var timestamp: Date
    var wpm: Double
    var session: Session?

    init(timestamp: Date, wpm: Double) {
        self.timestamp = timestamp
        self.wpm = wpm
    }
}

@Model
final class FillerCount {
    var word: String
    var count: Int
    var language: String
    var session: Session?

    init(word: String, count: Int, language: String) {
        self.word = word
        self.count = count
        self.language = language
    }
}

@Model
final class RepeatedPhrase {
    var phrase: String
    var count: Int
    var session: Session?

    init(phrase: String, count: Int) {
        self.phrase = phrase
        self.count = count
    }
}

// MARK: - Sendable records (cross actor boundaries safely)

nonisolated struct SessionRecord: Sendable, Equatable {
    var id: UUID
    var persistentModelID: PersistentIdentifier?
    var startedAt: Date
    var endedAt: Date
    var language: String
    var userLabel: String?
    var totalWords: Int
    var averageWPM: Double
    var peakWPM: Double
    var wpmStandardDeviation: Double
    var effectiveSpeakingDuration: TimeInterval
    var wpmSamples: [WPMSampleRecord]
    var fillerCounts: [FillerCountRecord]
    var repeatedPhrases: [RepeatedPhraseRecord]

    init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        language: String,
        userLabel: String? = nil,
        totalWords: Int,
        averageWPM: Double,
        peakWPM: Double,
        wpmStandardDeviation: Double,
        effectiveSpeakingDuration: TimeInterval,
        wpmSamples: [WPMSampleRecord] = [],
        fillerCounts: [FillerCountRecord] = [],
        repeatedPhrases: [RepeatedPhraseRecord] = []
    ) {
        self.id = id
        self.persistentModelID = nil
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.language = language
        self.userLabel = userLabel
        self.totalWords = totalWords
        self.averageWPM = averageWPM
        self.peakWPM = peakWPM
        self.wpmStandardDeviation = wpmStandardDeviation
        self.effectiveSpeakingDuration = effectiveSpeakingDuration
        self.wpmSamples = wpmSamples
        self.fillerCounts = fillerCounts
        self.repeatedPhrases = repeatedPhrases
    }
}

nonisolated struct WPMSampleRecord: Sendable, Equatable {
    var timestamp: Date
    var wpm: Double
}

nonisolated struct FillerCountRecord: Sendable, Equatable {
    var word: String
    var count: Int
    var language: String
}

nonisolated struct RepeatedPhraseRecord: Sendable, Equatable {
    var phrase: String
    var count: Int
}

// MARK: - EndedSession → SessionRecord factory

extension SessionRecord {
    nonisolated static func placeholder(from ended: EndedSession) -> SessionRecord {
        SessionRecord(
            startedAt: Date.distantPast,
            endedAt: Date.distantPast,
            language: "",
            totalWords: 0,
            averageWPM: 0,
            peakWPM: 0,
            wpmStandardDeviation: 0,
            effectiveSpeakingDuration: 0
        )
    }
}
