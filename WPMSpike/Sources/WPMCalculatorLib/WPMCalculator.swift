import Foundation

/// Sliding-window, VAD-aware words-per-minute calculator with EMA smoothing.
///
/// Uses a transition-based VAD model: each ``VADEvent`` marks when speech
/// starts or stops. The state holds until the next event. An empty VAD array
/// means the entire duration is assumed to be speaking.
///
/// When `speakingDuration == 0` but `wordCount > 0` (VAD/Speech disagreement),
/// the calculator holds the last-known smoothed value to avoid jitter.
public struct WPMCalculator: Sendable {
    private let windowSize: TimeInterval
    private let emaAlpha: Double
    private var smoother: EMASmoother
    private var words: [TimestampedWord] = []
    private var vadEvents: [VADEvent] = []
    private var lastSmoothedWPM: Double = 0
    private var totalWords: Int = 0
    private var totalSpeakingDuration: TimeInterval = 0
    private var lastSampleTimestamp: TimeInterval = 0

    public init(windowSize: TimeInterval, emaAlpha: Double) {
        self.windowSize = windowSize
        self.emaAlpha = emaAlpha
        self.smoother = EMASmoother(alpha: emaAlpha)
    }

    public mutating func addWord(_ word: TimestampedWord) {
        words.append(word)
    }

    public mutating func addVADEvent(_ event: VADEvent) {
        vadEvents.append(event)
    }

    public mutating func wpm(at timestamp: TimeInterval) -> WPMSample {
        let windowStart = max(0, timestamp - windowSize)

        let wordCount = words.count(where: { $0.startTime >= windowStart && $0.startTime < timestamp })
        let speakingDuration = computeSpeakingDuration(from: windowStart, to: timestamp)

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

        updateSessionAccumulators(from: lastSampleTimestamp, to: timestamp, wordCount: wordCount)
        lastSampleTimestamp = timestamp

        return WPMSample(timestamp: timestamp, rawWPM: rawWPM, smoothedWPM: smoothedWPM)
    }

    public var sessionAverageWPM: Double {
        guard totalSpeakingDuration > 0 else { return 0 }
        return Double(totalWords) / totalSpeakingDuration * 60.0
    }

    /// Batch convenience for spike/test usage. Default sampleInterval matches
    /// production widget update rate (3.0s per product spec).
    public func processAll(
        words: [TimestampedWord],
        vadEvents: [VADEvent],
        sampleInterval: TimeInterval = 3.0
    ) -> [WPMSample] {
        guard !words.isEmpty else { return [] }

        var calc = WPMCalculator(windowSize: windowSize, emaAlpha: emaAlpha)
        for vadEvent in vadEvents { calc.addVADEvent(vadEvent) }
        for word in words { calc.addWord(word) }

        let maxTime = words.map(\.endTime).max() ?? 0
        var samples: [WPMSample] = []
        var sampleTime = sampleInterval
        while sampleTime <= maxTime {
            samples.append(calc.wpm(at: sampleTime))
            sampleTime += sampleInterval
        }
        return samples
    }

    // MARK: - Private

    private func computeSpeakingDuration(from start: TimeInterval, to end: TimeInterval) -> TimeInterval {
        guard start < end else { return 0 }

        if vadEvents.isEmpty {
            return end - start
        }

        var speakingTime: TimeInterval = 0
        var currentlySpeaking = vadEvents.first.map { $0.isSpeaking } ?? true
        var segmentStart = start

        for event in vadEvents {
            if event.timestamp <= start {
                currentlySpeaking = event.isSpeaking
                segmentStart = start
                continue
            }

            if event.timestamp >= end {
                break
            }

            if currentlySpeaking {
                speakingTime += event.timestamp - segmentStart
            }
            segmentStart = event.timestamp
            currentlySpeaking = event.isSpeaking
        }

        if currentlySpeaking {
            speakingTime += end - segmentStart
        }

        return speakingTime
    }

    private mutating func updateSessionAccumulators(
        from previousTimestamp: TimeInterval,
        to currentTimestamp: TimeInterval,
        wordCount: Int
    ) {
        totalWords += wordCount
        let speaking = computeSpeakingDuration(from: previousTimestamp, to: currentTimestamp)
        totalSpeakingDuration += speaking
    }
}
