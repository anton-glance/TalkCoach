import SwiftUI
import XCTest
@testable import TalkCoach

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
}
