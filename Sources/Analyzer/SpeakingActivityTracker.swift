import Foundation

/// Derives speaking activity from token-arrival timestamps.
///
/// Speaking duration is computed from token intervals with gap bridging:
/// gaps between consecutive tokens shorter than `tokenSilenceTimeout` are
/// treated as continuing speech.
struct SpeakingActivityTracker: Sendable {
    private let tokenSilenceTimeout: TimeInterval
    private var tokenIntervals: [(start: TimeInterval, end: TimeInterval)] = []

    nonisolated init(tokenSilenceTimeout: TimeInterval = 1.5) {
        self.tokenSilenceTimeout = tokenSilenceTimeout
    }

    nonisolated mutating func addToken(_ token: TimestampedWord) {
        tokenIntervals.append((start: token.startTime, end: token.endTime))
    }

    /// Clears all accumulated token intervals. Called by WPMCalculator.newHop() on each hop boundary.
    nonisolated mutating func reset() {
        tokenIntervals.removeAll()
    }

    /// Sum of speaking duration within the given window.
    nonisolated func speakingDuration(in window: TimeRange) -> TimeInterval {
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
    nonisolated func isCurrentlySpeaking(asOf timestamp: TimeInterval) -> Bool {
        tokenIntervals.contains { interval in
            timestamp >= interval.start
                && timestamp <= interval.end + tokenSilenceTimeout
        }
    }
}
