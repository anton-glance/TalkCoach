import XCTest
@testable import TalkCoach

@MainActor
final class WPMCalculatorHopTests: XCTestCase {

    private func word(_ w: String, _ start: Double, _ end: Double) -> TimestampedWord {
        TimestampedWord(word: w, startTime: start, endTime: end)
    }

    /// AC-8: newHop() resets prior accumulation and uses new words + window bounds.
    func testNewHopReplacesAccumulatedWords() {
        var calc = WPMCalculator(windowSize: 10, emaAlpha: 1.0)
        // Prime with some words via addWord
        calc.addWord(word("old", 0.0, 1.0))

        let hopWords = [word("hello", 0.0, 0.3), word("world", 0.5, 0.8)]
        let sample = calc.newHop(words: hopWords, windowStart: 0.0, windowEnd: 10.0)

        // 2 words / speaking duration in [0,10]. Both tokens are within the window.
        XCTAssertGreaterThan(sample.smoothedWPM, 0, "WPM must be > 0 with 2 words")
        XCTAssertEqual(sample.timestamp, 10.0, accuracy: 0.001)
    }

    func testNewHopWithEmptyWordsReturnsZeroWPM() {
        var calc = WPMCalculator(windowSize: 10, emaAlpha: 1.0)
        let sample = calc.newHop(words: [], windowStart: 0.0, windowEnd: 10.0)
        XCTAssertEqual(sample.rawWPM, 0.0, accuracy: 0.001)
    }

    func testNewHopEMASmoothesBetweenCalls() {
        var calc = WPMCalculator(windowSize: 10, emaAlpha: 0.5)
        // First hop: 60 WPM (1 word per second for 1s)
        let w1 = [word("one", 0.0, 1.0)]
        let s1 = calc.newHop(words: w1, windowStart: 0.0, windowEnd: 1.0)
        // Second hop: 0 WPM (no words in 5s)
        let s2 = calc.newHop(words: [], windowStart: 1.0, windowEnd: 6.0)

        // After first hop smoothedWPM > 0; after second hop it should still be > 0 (EMA carryover)
        XCTAssertGreaterThan(s1.smoothedWPM, 0)
        XCTAssertGreaterThanOrEqual(s2.smoothedWPM, 0)
    }

    func testNewHopTimestampMatchesWindowEnd() {
        var calc = WPMCalculator(windowSize: 10, emaAlpha: 1.0)
        let sample = calc.newHop(words: [], windowStart: 5.0, windowEnd: 15.0)
        XCTAssertEqual(sample.timestamp, 15.0, accuracy: 0.001)
    }

    /// FM2: zero speaking-duration with words present must hold last WPM, not drop to 0.
    func testNewHop_zeroDenominator_holdsLastSmoothedValue() {
        var calc = WPMCalculator(windowSize: 10, emaAlpha: 1.0)
        // First hop: word with valid duration → positive WPM.
        let s1 = calc.newHop(words: [word("one", 0.0, 1.0)], windowStart: 0.0, windowEnd: 1.0)
        XCTAssertGreaterThan(s1.smoothedWPM, 0)
        // Second hop: zero-duration word → wordCount=1, speakingDuration=0.
        let s2 = calc.newHop(words: [word("two", 1.5, 1.5)], windowStart: 1.0, windowEnd: 2.0)
        XCTAssertGreaterThan(s2.smoothedWPM, 0,
            "FM2: zero speaking-duration with words present must hold last WPM, not drop to 0")
    }
}
