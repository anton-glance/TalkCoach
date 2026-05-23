import Foundation

/// A single recognized word with timing information.
struct TimestampedWord: Sendable {
    let word: String
    let startTime: TimeInterval
    let endTime: TimeInterval

    nonisolated init(word: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.word = word
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// A time interval defined by start and end points.
struct TimeRange: Sendable {
    let start: TimeInterval
    let end: TimeInterval

    nonisolated init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// A WPM measurement at a point in time.
/// WPM measurement produced by WPMCalculator. Named WPMReading to avoid conflict with
/// the SwiftData WPMSample model in Storage.
struct WPMReading: Sendable {
    let timestamp: TimeInterval
    let rawWPM: Double
    let smoothedWPM: Double

    nonisolated init(timestamp: TimeInterval, rawWPM: Double, smoothedWPM: Double) {
        self.timestamp = timestamp
        self.rawWPM = rawWPM
        self.smoothedWPM = smoothedWPM
    }
}

/// A hop batch delivered by ParakeetBackend to WPMCalculator.
struct WindowedWordCount: Sendable {
    let words: [TimestampedWord]
    let windowStart: TimeInterval
    let windowEnd: TimeInterval

    nonisolated init(words: [TimestampedWord], windowStart: TimeInterval, windowEnd: TimeInterval) {
        self.words = words
        self.windowStart = windowStart
        self.windowEnd = windowEnd
    }
}
