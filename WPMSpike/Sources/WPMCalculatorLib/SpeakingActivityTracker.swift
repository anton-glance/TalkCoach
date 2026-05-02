import Foundation

/// Derives speaking activity from `SpeechAnalyzer` token-arrival timestamps.
///
/// Replaces energy-based VAD. Speaking duration is computed from token intervals
/// with gap bridging: gaps between consecutive tokens that are shorter than
/// `tokenSilenceTimeout` are treated as continuing speech.
public struct SpeakingActivityTracker: Sendable {
    private let tokenSilenceTimeout: TimeInterval
    private var tokenIntervals: [(start: TimeInterval, end: TimeInterval)] = []

    public init(tokenSilenceTimeout: TimeInterval = 1.5) {
        self.tokenSilenceTimeout = tokenSilenceTimeout
    }

    /// Records a token's time interval.
    public mutating func addToken(_ token: TimestampedWord) {
        tokenIntervals.append((start: token.startTime, end: token.endTime))
    }

    /// Sum of speaking duration within the given window.
    ///
    /// Algorithm: clip token intervals to the window, sort by start time,
    /// merge consecutive intervals whose gap is within `tokenSilenceTimeout`,
    /// then sum the merged interval lengths.
    public func speakingDuration(in window: TimeRange) -> TimeInterval {
        guard window.start < window.end else { return 0 }

        var clipped: [(start: TimeInterval, end: TimeInterval)] = []
        for interval in tokenIntervals {
            let clampedStart = max(interval.start, window.start)
            let clampedEnd = min(interval.end, window.end)
            if clampedStart < clampedEnd {
                clipped.append((start: clampedStart, end: clampedEnd))
            }
        }

        guard !clipped.isEmpty else { return 0 }

        clipped.sort { $0.start < $1.start }

        var merged: [(start: TimeInterval, end: TimeInterval)] = [clipped[0]]
        for index in 1..<clipped.count {
            let gap = clipped[index].start - merged[merged.count - 1].end
            if gap <= tokenSilenceTimeout {
                merged[merged.count - 1].end = max(
                    merged[merged.count - 1].end,
                    clipped[index].end
                )
            } else {
                merged.append(clipped[index])
            }
        }

        return merged.reduce(0) { $0 + ($1.end - $1.start) }
    }

    /// Whether speech is active at the given timestamp.
    ///
    /// True if `timestamp` falls within `[token.startTime, token.endTime + tokenSilenceTimeout]`
    /// for any recorded token.
    public func isCurrentlySpeaking(asOf timestamp: TimeInterval) -> Bool {
        tokenIntervals.contains { interval in
            timestamp >= interval.start
                && timestamp <= interval.end + tokenSilenceTimeout
        }
    }
}
