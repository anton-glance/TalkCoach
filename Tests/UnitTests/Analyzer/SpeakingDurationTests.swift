import XCTest
@testable import TalkCoach

@MainActor
final class SpeakingDurationTests: XCTestCase {

    private func word(_ start: Double, _ end: Double) -> TimestampedWord {
        TimestampedWord(word: "x", startTime: start, endTime: end)
    }

    func testEmptyTrackerReturnZeroDuration() {
        var tracker = SpeakingActivityTracker()
        let duration = tracker.speakingDuration(in: TimeRange(start: 0, end: 10))
        XCTAssertEqual(duration, 0)
    }

    func testSingleTokenFullyCoveredByWindow() {
        var tracker = SpeakingActivityTracker()
        tracker.addToken(word(1.0, 2.0))
        let duration = tracker.speakingDuration(in: TimeRange(start: 0, end: 10))
        XCTAssertEqual(duration, 1.0, accuracy: 0.001)
    }

    func testAdjacentTokensAreMergedWithGapBridging() {
        var tracker = SpeakingActivityTracker()
        tracker.addToken(word(0.0, 1.0))
        tracker.addToken(word(1.5, 2.5)) // gap = 0.5s < tokenSilenceTimeout(1.5s) → merged
        let duration = tracker.speakingDuration(in: TimeRange(start: 0, end: 5))
        // Merged interval: [0, 2.5] → 2.5s
        XCTAssertEqual(duration, 2.5, accuracy: 0.001)
    }

    func testWideGapTokensAreNotMerged() {
        var tracker = SpeakingActivityTracker()
        tracker.addToken(word(0.0, 1.0))
        tracker.addToken(word(3.0, 4.0)) // gap = 2.0s > 1.5s → separate
        let duration = tracker.speakingDuration(in: TimeRange(start: 0, end: 5))
        XCTAssertEqual(duration, 2.0, accuracy: 0.001)
    }

    func testIsCurrentlySpeakingInsideTokenInterval() {
        var tracker = SpeakingActivityTracker()
        tracker.addToken(word(1.0, 2.0))
        XCTAssertTrue(tracker.isCurrentlySpeaking(asOf: 1.5))
    }

    func testIsCurrentlySpeakingWithinSilenceTimeout() {
        var tracker = SpeakingActivityTracker()
        tracker.addToken(word(1.0, 2.0))
        // 2.0 + 1.5 = 3.5 → isCurrentlySpeaking should be true at 3.0
        XCTAssertTrue(tracker.isCurrentlySpeaking(asOf: 3.0))
    }

    func testIsNotSpeakingBeyondSilenceTimeout() {
        var tracker = SpeakingActivityTracker()
        tracker.addToken(word(1.0, 2.0))
        // Beyond 2.0 + 1.5 = 3.5
        XCTAssertFalse(tracker.isCurrentlySpeaking(asOf: 4.0))
    }

    /// AC-7 (reset): after reset(), speaking duration returns 0 and new tokens accumulate fresh.
    func testResetClearsPriorTokens() {
        var tracker = SpeakingActivityTracker()
        tracker.addToken(word(0.0, 5.0))
        tracker.reset()
        let duration = tracker.speakingDuration(in: TimeRange(start: 0, end: 10))
        XCTAssertEqual(duration, 0, "After reset(), no prior tokens contribute to duration")
    }

    func testResetAllowsAccumulationAfterwards() {
        var tracker = SpeakingActivityTracker()
        tracker.addToken(word(0.0, 5.0))
        tracker.reset()
        tracker.addToken(word(6.0, 7.0))
        let duration = tracker.speakingDuration(in: TimeRange(start: 0, end: 10))
        XCTAssertEqual(duration, 1.0, accuracy: 0.001)
    }
}
