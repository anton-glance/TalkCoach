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

/// A voice activity detection transition event.
///
/// Uses a transition model: each event marks the moment speech starts or stops.
/// The state holds until the next event. If the array is empty, the entire
/// duration is assumed to be speaking.
public struct VADEvent: Sendable {
    public let timestamp: TimeInterval
    public let isSpeaking: Bool

    public init(timestamp: TimeInterval, isSpeaking: Bool) {
        self.timestamp = timestamp
        self.isSpeaking = isSpeaking
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
