import Foundation

/// Sliding-window, token-derived words-per-minute calculator with EMA smoothing.
///
/// Speaking duration is derived from `SpeakingActivityTracker` using token timestamps.
/// When `speakingDuration == 0` but `wordCount > 0` (token timing disagreement),
/// the calculator holds the last-known smoothed value to avoid jitter.
struct WPMCalculator: Sendable {
    private let windowSize: TimeInterval
    private let emaAlpha: Double
    private let tokenSilenceTimeout: TimeInterval
    private var smoother: EMASmoother
    private var words: [TimestampedWord] = []
    private var tracker: SpeakingActivityTracker
    private var lastSmoothedWPM: Double = 0

    nonisolated init(
        windowSize: TimeInterval,
        emaAlpha: Double,
        tokenSilenceTimeout: TimeInterval = 1.5
    ) {
        self.windowSize = windowSize
        self.emaAlpha = emaAlpha
        self.tokenSilenceTimeout = tokenSilenceTimeout
        self.smoother = EMASmoother(alpha: emaAlpha)
        self.tracker = SpeakingActivityTracker(tokenSilenceTimeout: tokenSilenceTimeout)
    }

    nonisolated mutating func addWord(_ word: TimestampedWord) {
        words.append(word)
        tracker.addToken(word)
    }

    nonisolated mutating func wpm(at timestamp: TimeInterval) -> WPMReading {
        let windowStart = max(0, timestamp - windowSize)
        let window = TimeRange(start: windowStart, end: timestamp)

        let wordCount = words.count(where: {
            $0.startTime >= windowStart && $0.startTime < timestamp
        })
        let speakingDuration = tracker.speakingDuration(in: window)

        let rawWPM: Double
        if wordCount > 0 && speakingDuration <= 0 {
            rawWPM = lastSmoothedWPM
        } else if speakingDuration > 0 {
            rawWPM = Double(wordCount) / speakingDuration * 60.0
        } else {
            rawWPM = 0
        }

        let smoothedWPM = smoother.smooth(rawWPM)
        lastSmoothedWPM = smoothedWPM

        return WPMReading(timestamp: timestamp, rawWPM: rawWPM, smoothedWPM: smoothedWPM)
    }

    nonisolated var totalSpeakingDuration: TimeInterval {
        if let maxEnd = words.map(\.endTime).max() {
            return tracker.speakingDuration(in: TimeRange(start: 0, end: maxEnd))
        }
        return 0
    }

    nonisolated var sessionAverageWPM: Double {
        guard !words.isEmpty else { return 0 }
        let speaking = totalSpeakingDuration
        guard speaking > 0 else { return 0 }
        return Double(words.count) / speaking * 60.0
    }
}
