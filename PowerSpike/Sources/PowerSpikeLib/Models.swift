import Foundation

public struct TimestampedWord: Sendable {
    public let word: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(word: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.word = word
        self.startTime = startTime
        self.endTime = endTime
    }
}

public struct TimeRange: Sendable {
    public let start: TimeInterval
    public let end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

public struct WPMSample: Sendable {
    public let timestamp: TimeInterval
    public let rawWPM: Double
    public let smoothedWPM: Double

    public init(timestamp: TimeInterval, rawWPM: Double, smoothedWPM: Double) {
        self.timestamp = timestamp
        self.rawWPM = rawWPM
        self.smoothedWPM = smoothedWPM
    }
}
