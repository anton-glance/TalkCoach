import Foundation

/// A single recognized word with timing information.
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

/// A time interval defined by start and end points.
public struct TimeRange: Sendable {
    public let start: TimeInterval
    public let end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// A WPM measurement at a point in time.
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
