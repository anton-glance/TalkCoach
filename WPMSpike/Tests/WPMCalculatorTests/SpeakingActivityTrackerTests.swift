import Foundation
import Testing
@testable import WPMCalculatorLib

struct SpeakingActivityTrackerTests {

    @Test func speakingDuration_emptyTokens_returnsZero() {
        let tracker = SpeakingActivityTracker(tokenSilenceTimeout: 1.5)
        let duration = tracker.speakingDuration(
            in: TimeRange(start: 0, end: 10)
        )
        #expect(duration == 0, "Empty tracker should return 0 speaking duration")
    }

    @Test func speakingDuration_fullyContainedTokens_sumsExactly() {
        // Tokens: [1,2], [3,4], [5,6]. Window [0, 10].
        // Gaps between tokens = 1.0s each, < 1.5s timeout → bridged.
        // Bridged region: [1, 6] = 5.0s.
        var tracker = SpeakingActivityTracker(tokenSilenceTimeout: 1.5)
        tracker.addToken(TimestampedWord(word: "a", startTime: 1, endTime: 2))
        tracker.addToken(TimestampedWord(word: "b", startTime: 3, endTime: 4))
        tracker.addToken(TimestampedWord(word: "c", startTime: 5, endTime: 6))

        let duration = tracker.speakingDuration(
            in: TimeRange(start: 0, end: 10)
        )
        #expect(
            abs(duration - 5.0) < 0.001,
            "Expected 5.0s (bridged [1,6]), got \(duration)"
        )
    }

    @Test func speakingDuration_partiallyContainedTokens_clipsToWindow() {
        // Token [2, 8]. Window [5, 10].
        // Clipped to [5, 8] = 3.0s.
        var tracker = SpeakingActivityTracker(tokenSilenceTimeout: 1.5)
        tracker.addToken(TimestampedWord(word: "a", startTime: 2, endTime: 8))

        let duration = tracker.speakingDuration(
            in: TimeRange(start: 5, end: 10)
        )
        #expect(
            abs(duration - 3.0) < 0.001,
            "Expected 3.0s (clipped [5,8]), got \(duration)"
        )
    }

    @Test func speakingDuration_silenceTimeoutAffectsGapBridging() {
        // Two tokens: [1, 2] and [4.5, 5.5]. Gap = 2.5s. Window [0, 10].
        // At timeout 1.5: gap NOT bridged → 1.0 + 1.0 = 2.0s
        // At timeout 3.0: gap bridged → [1, 5.5] = 4.5s
        let tokenA = TimestampedWord(word: "a", startTime: 1, endTime: 2)
        let tokenB = TimestampedWord(word: "b", startTime: 4.5, endTime: 5.5)
        let window = TimeRange(start: 0, end: 10)

        var shortTimeout = SpeakingActivityTracker(tokenSilenceTimeout: 1.5)
        shortTimeout.addToken(tokenA)
        shortTimeout.addToken(tokenB)
        let shortDuration = shortTimeout.speakingDuration(in: window)

        var longTimeout = SpeakingActivityTracker(tokenSilenceTimeout: 3.0)
        longTimeout.addToken(tokenA)
        longTimeout.addToken(tokenB)
        let longDuration = longTimeout.speakingDuration(in: window)

        #expect(
            abs(shortDuration - 2.0) < 0.001,
            "Timeout 1.5: gap 2.5s not bridged → 2.0s, got \(shortDuration)"
        )
        #expect(
            abs(longDuration - 4.5) < 0.001,
            "Timeout 3.0: gap 2.5s bridged → 4.5s, got \(longDuration)"
        )
    }

    @Test func isCurrentlySpeaking_recentToken_returnsTrue() {
        // Token [5.0, 6.0], timeout 1.5. Query at 7.0.
        // 7.0 ∈ [5.0, 6.0 + 1.5] = [5.0, 7.5] → true
        var tracker = SpeakingActivityTracker(tokenSilenceTimeout: 1.5)
        tracker.addToken(
            TimestampedWord(word: "a", startTime: 5.0, endTime: 6.0)
        )

        #expect(
            tracker.isCurrentlySpeaking(asOf: 7.0),
            "7.0 is within [5.0, 7.5], should be speaking"
        )
    }

    @Test func isCurrentlySpeaking_oldToken_returnsFalse() {
        // Token [5.0, 6.0], timeout 1.5. Query at 8.0.
        // 8.0 ∉ [5.0, 7.5] → false
        var tracker = SpeakingActivityTracker(tokenSilenceTimeout: 1.5)
        tracker.addToken(
            TimestampedWord(word: "a", startTime: 5.0, endTime: 6.0)
        )

        #expect(
            !tracker.isCurrentlySpeaking(asOf: 8.0),
            "8.0 is outside [5.0, 7.5], should not be speaking"
        )
    }
}
