import Foundation
import Testing
@testable import WPMCalculatorLib

struct WPMCalculatorTests {

    // MARK: - Helpers

    /// Creates evenly spaced words over a duration.
    private func makeEvenlySpacedWords(
        count: Int,
        over duration: TimeInterval
    ) -> [TimestampedWord] {
        let interval = duration / Double(count)
        return (0..<count).map { index in
            let start = Double(index) * interval
            return TimestampedWord(
                word: "word\(index)",
                startTime: start,
                endTime: start + interval * 0.8
            )
        }
    }

    // MARK: - Tests

    @Test func evenlySpacedWords_yieldsExpectedWPM() {
        // 60 words over 30s = 0.5s intervals, 0.4s token duration.
        // Token-derived speaking duration in [17,25] window = 24.9 - 17.0 = 7.9s
        // (all 0.1s inter-token gaps bridged by 1.5s timeout).
        // 16 words / 7.9s * 60 = ~121.5 WPM.
        let words = makeEvenlySpacedWords(count: 60, over: 30.0)
        var calc = WPMCalculator(windowSize: 8.0, emaAlpha: 0.3)
        for word in words { calc.addWord(word) }

        let sample = calc.wpm(at: 25.0)
        #expect(
            sample.smoothedWPM > 120.3 && sample.smoothedWPM < 122.7,
            "Expected ~121.5 WPM ± 1%, got \(sample.smoothedWPM)"
        )
    }

    @Test func silenceAtEnd_tokenGapsReduceSpeakingDuration() {
        // 60 words in first 10s (6 words/sec = 360 WPM speaking rate).
        // No words in 10–30s. Token-derived: speaking only in [0, 10s].
        // Window 5s at t=9s covers [4, 9]. Tokens densely cover this range.
        // Speaking duration ≈ 5s. ~30 words in window → ~360 WPM.
        let words = makeEvenlySpacedWords(count: 60, over: 10.0)

        var calc = WPMCalculator(windowSize: 5.0, emaAlpha: 0.3)
        for word in words { calc.addWord(word) }

        let sample = calc.wpm(at: 9.0)
        #expect(
            sample.smoothedWPM > 342.0 && sample.smoothedWPM < 378.0,
            "Expected ~360 WPM ± 5%, got \(sample.smoothedWPM)"
        )
    }

    @Test func fourSecondPauseMidStream_doesNotCrashWPM() {
        // ~120 WPM (2 words/sec) for 10s, 4s gap (10–14s), ~120 WPM for 10s (14–24s).
        // 4s gap > tokenSilenceTimeout (1.5s) → not bridged.
        // Window 8s, alpha 0.3.
        var words: [TimestampedWord] = []
        for index in 0..<20 {
            let start = Double(index) * 0.5
            words.append(TimestampedWord(
                word: "a\(index)", startTime: start, endTime: start + 0.4
            ))
        }
        for index in 0..<20 {
            let start = 14.0 + Double(index) * 0.5
            words.append(TimestampedWord(
                word: "b\(index)", startTime: start, endTime: start + 0.4
            ))
        }

        var calc = WPMCalculator(windowSize: 8.0, emaAlpha: 0.3)
        for word in words { calc.addWord(word) }

        let prePause = calc.wpm(at: 9.0)
        let midPause = calc.wpm(at: 12.0)

        #expect(
            midPause.smoothedWPM >= prePause.smoothedWPM * 0.9,
            "WPM during pause (\(midPause.smoothedWPM)) dropped below 90% of pre-pause (\(prePause.smoothedWPM))"
        )
        #expect(
            midPause.smoothedWPM > 0,
            "WPM during pause must not be 0"
        )
    }

    @Test func graduallyIncreasingRate_WPMTrendsUp() {
        // Words at gradually increasing rate: 1/sec at start, ~3/sec by 30s.
        // Token-derived speaking duration. Window 5s, alpha 0.3.
        // Sample every 1s from t=10s. Each sample >= previous.
        var words: [TimestampedWord] = []
        var currentTime = 0.0
        while currentTime < 30.0 {
            let rate = 1.0 + (currentTime / 30.0) * 2.0
            let interval = 1.0 / rate
            words.append(TimestampedWord(
                word: "w",
                startTime: currentTime,
                endTime: currentTime + interval * 0.8
            ))
            currentTime += interval
        }

        let samples = WPMCalculator(windowSize: 5.0, emaAlpha: 0.3)
            .processAll(words: words, sampleInterval: 1.0)

        let relevantSamples = samples.filter { $0.timestamp >= 10.0 }
        for index in 1..<relevantSamples.count {
            #expect(
                relevantSamples[index].smoothedWPM >= relevantSamples[index - 1].smoothedWPM,
                "WPM not monotonically increasing at t=\(relevantSamples[index].timestamp)"
            )
        }
    }

    @Test func emptyTokenStream_returnsZeroNotCrash() {
        // No words. processAll returns empty or all-zero.
        let samples = WPMCalculator(windowSize: 8.0, emaAlpha: 0.3)
            .processAll(words: [], sampleInterval: 3.0)

        for sample in samples {
            #expect(!sample.smoothedWPM.isNaN, "WPM must not be NaN")
            #expect(!sample.smoothedWPM.isInfinite, "WPM must not be infinite")
            #expect(sample.smoothedWPM == 0.0, "WPM must be 0 for empty input")
        }
    }
}
