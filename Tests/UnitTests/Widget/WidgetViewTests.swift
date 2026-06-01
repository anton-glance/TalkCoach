import SwiftUI
import XCTest
@testable import TalkCoach

// swiftlint:disable:next type_body_length
@MainActor final class WidgetViewTests: XCTestCase {

    // MARK: - Construction smoke (body must not crash for each viewModel state)

    func testConstructsWithNilWPM() {
        let viewModel = WidgetViewModel()
        let view = WidgetView(viewModel: viewModel, onDismiss: {})
        _ = view.body
    }

    func testConstructsInSlowZone() {
        let viewModel = WidgetViewModel()
        viewModel.currentWPMVoiced = 80
        viewModel.activityState = .counting
        let view = WidgetView(viewModel: viewModel, onDismiss: {})
        _ = view.body
    }

    func testConstructsInIdealZone() {
        let viewModel = WidgetViewModel()
        viewModel.currentWPMVoiced = 140
        viewModel.activityState = .counting
        let view = WidgetView(viewModel: viewModel, onDismiss: {})
        _ = view.body
    }

    func testConstructsInFastZone() {
        let viewModel = WidgetViewModel()
        viewModel.currentWPMVoiced = 200
        viewModel.activityState = .counting
        let view = WidgetView(viewModel: viewModel, onDismiss: {})
        _ = view.body
    }

    func testConstructsWithHighStreak() {
        let viewModel = WidgetViewModel()
        viewModel.currentWPMVoiced = 150
        viewModel.activityState = .counting
        viewModel.streakSeconds = 200
        let view = WidgetView(viewModel: viewModel, onDismiss: {})
        _ = view.body
    }

    // MARK: - formatMonoTime

    func testFormatZeroSeconds() {
        let result = WidgetView.formatMonoTime(0)
        XCTAssertEqual(result.minutes, "0")
        XCTAssertEqual(result.seconds, "00")
    }

    func testFormatFiveSeconds() {
        let result = WidgetView.formatMonoTime(5)
        XCTAssertEqual(result.minutes, "0")
        XCTAssertEqual(result.seconds, "05")
    }

    func testFormatSixtySeconds() {
        let result = WidgetView.formatMonoTime(60)
        XCTAssertEqual(result.minutes, "1")
        XCTAssertEqual(result.seconds, "00")
    }

    func testFormatNinetySeconds() {
        let result = WidgetView.formatMonoTime(90)
        XCTAssertEqual(result.minutes, "1")
        XCTAssertEqual(result.seconds, "30")
    }

    func testFormatNegativeClampsToZero() {
        let result = WidgetView.formatMonoTime(-1)
        XCTAssertEqual(result.minutes, "0")
        XCTAssertEqual(result.seconds, "00")
    }

    // MARK: - monoLabelText

    func testMonoLabelBelowL2IsMonologue() {
        XCTAssertEqual(WidgetView.monoLabelText(streakSeconds: 0, l2Seconds: 90), "MONOLOGUE")
    }

    func testMonoLabelJustBelowL2IsMonologue() {
        XCTAssertEqual(WidgetView.monoLabelText(streakSeconds: 89.9, l2Seconds: 90), "MONOLOGUE")
    }

    func testMonoLabelAtL2FlipsTakeAPause() {
        // L2 boundary is inclusive on the urgent side: streakSeconds >= l2Seconds → TAKE A PAUSE.
        XCTAssertEqual(WidgetView.monoLabelText(streakSeconds: 90, l2Seconds: 90), "TAKE A PAUSE")
    }

    func testMonoLabelWithCustomL2() {
        XCTAssertEqual(WidgetView.monoLabelText(streakSeconds: 61, l2Seconds: 61), "TAKE A PAUSE")
    }

    func testMonoLabelWithZeroL2ReturnsTakeAPause() {
        // Defensive: l2 ≤ 0 means any streak is urgent.
        XCTAssertEqual(WidgetView.monoLabelText(streakSeconds: 0, l2Seconds: 0), "TAKE A PAUSE")
    }

    // MARK: - monoCaretFraction

    func testCaretFractionAtZero() {
        XCTAssertEqual(WidgetView.monoCaretFraction(streakSeconds: 0, l3Seconds: 150), 0.0, accuracy: 1e-9)
    }

    func testCaretFractionAtL3() {
        XCTAssertEqual(WidgetView.monoCaretFraction(streakSeconds: 150, l3Seconds: 150), 1.0, accuracy: 1e-9)
    }

    func testCaretFractionPastL3Clamped() {
        XCTAssertEqual(WidgetView.monoCaretFraction(streakSeconds: 200, l3Seconds: 150), 1.0, accuracy: 1e-9)
    }

    func testCaretFractionNegativeClamped() {
        XCTAssertEqual(WidgetView.monoCaretFraction(streakSeconds: -5, l3Seconds: 150), 0.0, accuracy: 1e-9)
    }

    func testCaretFractionWithZeroL3ReturnsZero() {
        // Defensive: l3 ≤ 0 would divide by zero — return 0 (caret at left edge).
        XCTAssertEqual(WidgetView.monoCaretFraction(streakSeconds: 100, l3Seconds: 0), 0.0, accuracy: 1e-9)
    }

    func testCaretFractionWithNegativeL3ReturnsZero() {
        XCTAssertEqual(WidgetView.monoCaretFraction(streakSeconds: 100, l3Seconds: -10), 0.0, accuracy: 1e-9)
    }

    // MARK: - M5.4 cold-start predicate

    func testColdStartPredicateTrueWhenIdle() {
        // .idle covers the backing store while the panel is hidden between sessions, so the
        // very first visible frame is the cold-start mark and never a dashes frame.
        XCTAssertTrue(WidgetView.showColdStartMark(activityState: .idle, hasReceivedWPM: false))
    }

    func testColdStartPredicateFalseWhenIdleWithWPM() {
        XCTAssertFalse(WidgetView.showColdStartMark(activityState: .idle, hasReceivedWPM: true))
    }

    func testColdStartPredicateTrueWhenCountingWithoutWPM() {
        XCTAssertTrue(WidgetView.showColdStartMark(activityState: .counting, hasReceivedWPM: false))
    }

    func testColdStartPredicateFalseWhenCountingWithWPM() {
        XCTAssertFalse(WidgetView.showColdStartMark(activityState: .counting, hasReceivedWPM: true))
    }

    func testColdStartPredicateTrueWhenWarmingWithoutWPM() {
        // .warming covers the ~10s engine-load window before first token; mark must show immediately.
        XCTAssertTrue(WidgetView.showColdStartMark(activityState: .warming, hasReceivedWPM: false))
    }

    func testColdStartPredicateFalseWhenWarmingWithWPM() {
        // Shouldn't happen in practice but tests predicate completeness.
        XCTAssertFalse(WidgetView.showColdStartMark(activityState: .warming, hasReceivedWPM: true))
    }

    func testColdStartPredicateFalseWhenWaiting() {
        XCTAssertFalse(WidgetView.showColdStartMark(activityState: .waiting, hasReceivedWPM: false))
    }

    func testColdStartPredicate_true_whenWrappingAndNoWPM() {
        // Session ends in .warming (no WPM ever arrived) → activityState transitions to .wrapping.
        // The mark must hold through the 3+2s linger fade, not snap to dashes.
        XCTAssertTrue(
            WidgetView.showColdStartMark(activityState: .wrapping, hasReceivedWPM: false),
            "cold-start mark must show during .wrapping when no WPM ever arrived — mark holds through linger fade"
        )
    }

    func testColdStartPredicate_false_whenWrappingWithWPM() {
        // Session ends normally from .counting (WPM did arrive) → .wrapping + isFrozen=true.
        // The frozen branch renders last-known numbers, not the cold-start mark.
        XCTAssertFalse(
            WidgetView.showColdStartMark(activityState: .wrapping, hasReceivedWPM: true),
            "cold-start mark must NOT show during .wrapping when WPM arrived — isFrozen branch holds numbers"
        )
    }

    // MARK: - M5.4a waiting-hold: mark must not reappear on mid-session resume

    func testColdStartPredicate_false_whenWaiting_hasReceivedWPMTrue() {
        // .waiting is outside the predicate's left clause (only .idle/.warming/.counting are included),
        // so hasReceivedWPM is irrelevant for correctness — this test documents the M5.4a requirement:
        // during a mid-session silence pause the cold-start mark must never reappear.
        XCTAssertFalse(
            WidgetView.showColdStartMark(activityState: .waiting, hasReceivedWPM: true),
            "cold-start mark must not appear in .waiting state (hasReceivedWPM=true): dashes hold until new WPM arrives (M5.4a)"
        )
    }

    // MARK: - M5.4 effectiveDuration helper

    func testEffectiveDurationReducedMotionReturnsZero() {
        XCTAssertEqual(WidgetView.effectiveDuration(0.4, reducedMotion: true), 0.0, accuracy: 1e-9)
    }

    func testEffectiveDurationNormalReturnsSpec() {
        XCTAssertEqual(WidgetView.effectiveDuration(0.4, reducedMotion: false), 0.4, accuracy: 1e-9)
    }

    // MARK: - M5.4 construction smoke

    func testConstructsInColdStartState() {
        let viewModel = WidgetViewModel()
        viewModel.activityState = .counting
        viewModel.currentWPMVoiced = nil
        viewModel.hasReceivedWPM = false
        let view = WidgetView(viewModel: viewModel, onDismiss: {})
        _ = view.body
    }

    func testConstructsInWarmingColdStartState() {
        // .warming + no WPM → showColdStart = true; body must render ColdStartMarkView branch without crash.
        let viewModel = WidgetViewModel()
        viewModel.activityState = .warming
        viewModel.hasReceivedWPM = false
        let view = WidgetView(viewModel: viewModel, onDismiss: {})
        _ = view.body
    }

    func testConstructsInWrappingFrozenState() {
        let viewModel = WidgetViewModel()
        viewModel.activityState = .wrapping
        viewModel.currentWPMVoiced = 145
        viewModel.isFrozen = true
        let view = WidgetView(viewModel: viewModel, onDismiss: {})
        _ = view.body
    }

    func testConstructsInWaitingState() {
        let viewModel = WidgetViewModel()
        viewModel.activityState = .waiting
        viewModel.currentWPMVoiced = nil
        let view = WidgetView(viewModel: viewModel, onDismiss: {})
        _ = view.body
    }

    // MARK: - M5.5 hover scale helper

    func testHoverScale_notHovered_returnsResting() {
        XCTAssertEqual(WidgetView.hoverScale(isHovered: false, reducedMotion: false), 1.0, accuracy: 1e-9)
    }

    func testHoverScale_hovered_returnsSpec() {
        // Spec: scale 1.02 on hover. DesignTokens.Layout.hoverScale=1.025 is pre-iteration stale.
        XCTAssertEqual(WidgetView.hoverScale(isHovered: true, reducedMotion: false), 1.02, accuracy: 1e-9)
    }

    func testHoverScale_reducedMotion_snapsToResting() {
        // Reduce Motion suppresses scale entirely — instant snap to 1.0, no animation.
        XCTAssertEqual(WidgetView.hoverScale(isHovered: true, reducedMotion: true), 1.0, accuracy: 1e-9)
    }

    // MARK: - M5.5 hover y-offset helper

    func testHoverYOffset_notHovered_returnsZero() {
        XCTAssertEqual(WidgetView.hoverYOffset(isHovered: false, reducedMotion: false), 0.0, accuracy: 1e-9)
    }

    func testHoverYOffset_hovered_returnsLift() {
        // Spec: +1pt lift = y offset -1 (negative-up in SwiftUI coordinate system).
        XCTAssertEqual(WidgetView.hoverYOffset(isHovered: true, reducedMotion: false), -1.0, accuracy: 1e-9)
    }

    func testHoverYOffset_reducedMotion_snapsToZero() {
        // Reduce Motion suppresses lift — instant snap to 0, no animation.
        XCTAssertEqual(WidgetView.hoverYOffset(isHovered: true, reducedMotion: true), 0.0, accuracy: 1e-9)
    }

    // MARK: - M5.5 X button opacity helper

    func testXButtonOpacity_notHovered_isZero() {
        XCTAssertEqual(WidgetView.xButtonOpacity(isHovered: false), 0.0, accuracy: 1e-9)
    }

    func testXButtonOpacity_hovered_isOne_regardlessOfReducedMotion() {
        // Reduce Motion gates only the kinetic part (scale/lift). The X reveal is always
        // on hover — reducedMotion has no effect on xButtonOpacity. Both branches must be 1.0.
        XCTAssertEqual(WidgetView.xButtonOpacity(isHovered: true), 1.0, accuracy: 1e-9,
                       "X reveal must appear on hover even when Reduce Motion is enabled")
    }

    // MARK: - M5.5 tint alpha branch

    func testEffectiveTintAlpha_glassMode_returnsGlassAlpha() {
        // reduceTransparency=false → glass mode → lower alpha so lensing is visible.
        XCTAssertEqual(WidgetView.effectiveTintAlpha(reduceTransparency: false), 0.60, accuracy: 1e-9)
    }

    func testEffectiveTintAlpha_solidMode_returnsSolidAlpha() {
        // reduceTransparency=true → solid mode → full alpha (sized for opaque background).
        XCTAssertEqual(WidgetView.effectiveTintAlpha(reduceTransparency: true), 0.78, accuracy: 1e-9)
    }

    // MARK: - M5.5 construction smoke (reduceTransparency branches)

    func testConstructs_reduceTransparency_true() {
        // Solid background branch: body must not crash with reduceTransparencyProvider returning true.
        let viewModel = WidgetViewModel()
        viewModel.activityState = .warming
        viewModel.hasReceivedWPM = false
        let view = WidgetView(
            viewModel: viewModel,
            onDismiss: {},
            reduceTransparencyProvider: { true }
        )
        _ = view.body
    }

    func testConstructs_reduceTransparency_false() {
        // Glass branch: body must not crash with reduceTransparencyProvider returning false.
        let viewModel = WidgetViewModel()
        viewModel.activityState = .counting
        viewModel.currentWPMVoiced = 140
        viewModel.hasReceivedWPM = true
        let view = WidgetView(
            viewModel: viewModel,
            onDismiss: {},
            reduceTransparencyProvider: { false }
        )
        _ = view.body
    }

    // MARK: - M5.6 shouldPulseBottomCluster predicate

    func testShouldPulse_L3_counting_normalMotion_isTrue() {
        XCTAssertTrue(WidgetView.shouldPulseBottomCluster(
            monologueLevel: 3, reducedMotion: false, activityState: .counting))
    }

    func testShouldPulse_L3_counting_reducedMotion_isFalse() {
        XCTAssertFalse(WidgetView.shouldPulseBottomCluster(
            monologueLevel: 3, reducedMotion: true, activityState: .counting))
    }

    func testShouldPulse_L2_counting_normalMotion_isFalse() {
        XCTAssertFalse(WidgetView.shouldPulseBottomCluster(
            monologueLevel: 2, reducedMotion: false, activityState: .counting))
    }

    func testShouldPulse_L3_waiting_normalMotion_isFalse() {
        XCTAssertFalse(WidgetView.shouldPulseBottomCluster(
            monologueLevel: 3, reducedMotion: false, activityState: .waiting))
    }

    func testShouldPulse_L3_wrapping_normalMotion_isFalse() {
        XCTAssertFalse(WidgetView.shouldPulseBottomCluster(
            monologueLevel: 3, reducedMotion: false, activityState: .wrapping))
    }

    // MARK: - M5.6 construction smoke

    func testConstructs_monologueL3_counting_doesNotCrash() {
        let viewModel = WidgetViewModel()
        viewModel.monologueLevel = 3
        viewModel.activityState = .counting
        viewModel.currentWPMVoiced = 140
        viewModel.hasReceivedWPM = true
        viewModel.streakSeconds = 130
        let view = WidgetView(viewModel: viewModel, onDismiss: {})
        _ = view.body
    }
}
