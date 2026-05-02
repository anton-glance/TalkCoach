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
        return (0..<count).map { i in
            let start = Double(i) * interval
            return TimestampedWord(
                word: "word\(i)",
                startTime: start,
                endTime: start + interval * 0.8
            )
        }
    }

    // MARK: - Tests

    @Test func evenlySpacedWords_yieldsExpectedWPM() {
        // 60 words evenly over 30s = 2 words/sec = 120 WPM
        // VAD: all speaking (empty array = assume all speaking)
        // Window 8s, alpha 0.3. Sample at t=25s (well past warm-up).
        let words = makeEvenlySpacedWords(count: 60, over: 30.0)
        var calc = WPMCalculator(windowSize: 8.0, emaAlpha: 0.3)
        for w in words { calc.addWord(w) }

        let sample = calc.wpm(at: 25.0)
        #expect(
            sample.smoothedWPM > 118.8 && sample.smoothedWPM < 121.2,
            "Expected 120 WPM ± 1%, got \(sample.smoothedWPM)"
        )
    }

    @Test func silenceAtEnd_VADExcludesItFromDenominator() {
        // 60 words in first 10s (6 words/sec = 360 WPM).
        // VAD: speaking 0–10s, silent 10–30s.
        // Window 5s, alpha 0.3. Sample at t=9s.
        // Expect ~360 WPM (±5%), NOT ~120.
        let words = makeEvenlySpacedWords(count: 60, over: 10.0)
        let vadEvents = [
            VADEvent(timestamp: 0.0, isSpeaking: true),
            VADEvent(timestamp: 10.0, isSpeaking: false),
        ]

        var calc = WPMCalculator(windowSize: 5.0, emaAlpha: 0.3)
        for v in vadEvents { calc.addVADEvent(v) }
        for w in words { calc.addWord(w) }

        let sample = calc.wpm(at: 9.0)
        #expect(
            sample.smoothedWPM > 342.0 && sample.smoothedWPM < 378.0,
            "Expected ~360 WPM ± 5%, got \(sample.smoothedWPM)"
        )
    }

    @Test func fourSecondPauseMidStream_doesNotCrashWPM() {
        // ~120 WPM (2 words/sec) for 10s, 4s silence (10–14s), ~120 WPM for 10s (14–24s).
        // VAD: speaking 0–10s, silent 10–14s, speaking 14–24s.
        // Window 8s, alpha 0.3.
        var words: [TimestampedWord] = []
        // First segment: 20 words over 10s
        for i in 0..<20 {
            let start = Double(i) * 0.5
            words.append(TimestampedWord(word: "a\(i)", startTime: start, endTime: start + 0.4))
        }
        // Second segment: 20 words over 10s starting at 14s
        for i in 0..<20 {
            let start = 14.0 + Double(i) * 0.5
            words.append(TimestampedWord(word: "b\(i)", startTime: start, endTime: start + 0.4))
        }

        let vadEvents = [
            VADEvent(timestamp: 0.0, isSpeaking: true),
            VADEvent(timestamp: 10.0, isSpeaking: false),
            VADEvent(timestamp: 14.0, isSpeaking: true),
        ]

        var calc = WPMCalculator(windowSize: 8.0, emaAlpha: 0.3)
        for v in vadEvents { calc.addVADEvent(v) }
        for w in words { calc.addWord(w) }

        // Pre-pause WPM at t=9s
        let prePause = calc.wpm(at: 9.0)
        // Mid-pause WPM at t=12s
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
        // VAD: all speaking (empty). Window 5s, alpha 0.3.
        // Sample every 5s from t=10s. Each sample >= previous.
        var words: [TimestampedWord] = []
        var t = 0.0
        while t < 30.0 {
            let rate = 1.0 + (t / 30.0) * 2.0 // 1 word/sec → 3 words/sec
            let interval = 1.0 / rate
            words.append(TimestampedWord(word: "w", startTime: t, endTime: t + interval * 0.8))
            t += interval
        }

        let samples = WPMCalculator(windowSize: 5.0, emaAlpha: 0.3)
            .processAll(words: words, vadEvents: [], sampleInterval: 1.0)

        // Check samples from t=10s onward are monotonically increasing
        let relevantSamples = samples.filter { $0.timestamp >= 10.0 }
        for i in 1..<relevantSamples.count {
            #expect(
                relevantSamples[i].smoothedWPM >= relevantSamples[i - 1].smoothedWPM,
                "WPM not monotonically increasing at t=\(relevantSamples[i].timestamp): \(relevantSamples[i].smoothedWPM) < \(relevantSamples[i - 1].smoothedWPM)"
            )
        }
    }

    @Test func emptyTokenStream_returnsZeroNotCrash() {
        // No words, no VAD events. processAll returns empty or all-zero.
        // No crash, no NaN, no infinity.
        let samples = WPMCalculator(windowSize: 8.0, emaAlpha: 0.3)
            .processAll(words: [], vadEvents: [], sampleInterval: 3.0)

        for sample in samples {
            #expect(!sample.smoothedWPM.isNaN, "WPM must not be NaN")
            #expect(!sample.smoothedWPM.isInfinite, "WPM must not be infinite")
            #expect(sample.smoothedWPM == 0.0, "WPM must be 0 for empty input")
        }
    }
}
