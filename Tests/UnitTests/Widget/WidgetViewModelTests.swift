import Combine
import XCTest
@testable import TalkCoach

@MainActor
final class WidgetViewModelTests: XCTestCase {

    private var defaults: UserDefaults!
    private var settings: SettingsStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "WidgetViewModelTests.\(name)")!
        defaults.removePersistentDomain(forName: "WidgetViewModelTests.\(name)")
        settings = SettingsStore(userDefaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "WidgetViewModelTests.\(name)")
        super.tearDown()
    }

    // MARK: - 1. New fields presence and defaults

    func testWidgetViewModelHasStreakSeconds() {
        let viewModel = WidgetViewModel(settings: settings)
        XCTAssertEqual(viewModel.streakSeconds, 0, "streakSeconds must default to 0")
    }

    func testWidgetViewModelHasMonoL1Seconds() {
        let viewModel = WidgetViewModel(settings: settings)
        XCTAssertEqual(viewModel.monoL1Seconds, settings.monologueLevel1Minutes * 60, accuracy: 0.001,
            "monoL1Seconds must mirror settings default (L1 in seconds)")
    }

    func testWidgetViewModelHasMonoL2Seconds() {
        let viewModel = WidgetViewModel(settings: settings)
        XCTAssertEqual(viewModel.monoL2Seconds, settings.monologueLevel2Minutes * 60, accuracy: 0.001,
            "monoL2Seconds must mirror settings default (L2 in seconds)")
    }

    func testWidgetViewModelHasMonoL3Seconds() {
        let viewModel = WidgetViewModel(settings: settings)
        XCTAssertEqual(viewModel.monoL3Seconds, settings.monologueLevel3Minutes * 60, accuracy: 0.001,
            "monoL3Seconds must mirror settings default (L3 in seconds)")
    }

    func testWidgetViewModelHasMonoPauseSeconds() {
        let viewModel = WidgetViewModel(settings: settings)
        XCTAssertEqual(viewModel.monoPauseSeconds, settings.wpmPauseThreshold, accuracy: 0.001,
            "monoPauseSeconds must mirror settings.wpmPauseThreshold default")
    }

    // MARK: - 2. isIdle derivation

    func testIsIdleWhenActivityStateNotCounting() {
        let viewModel = WidgetViewModel(settings: settings)
        viewModel.activityState = .waiting
        viewModel.currentWPMVoiced = 130
        XCTAssertTrue(viewModel.isIdle,
            "isIdle must be true when activityState != .counting, regardless of WPM")
    }

    func testIsIdleWhenWPMNil() {
        let viewModel = WidgetViewModel(settings: settings)
        viewModel.activityState = .counting
        viewModel.currentWPMVoiced = nil
        XCTAssertTrue(viewModel.isIdle,
            "isIdle must be true when counting but WPM is nil (calculator hasn't fired yet)")
    }

    func testIsActiveWhenCountingAndWPMPresent() {
        let viewModel = WidgetViewModel(settings: settings)
        viewModel.activityState = .counting
        viewModel.currentWPMVoiced = 120
        XCTAssertFalse(viewModel.isIdle,
            "isIdle must be false when activityState == .counting AND WPM is non-nil")
    }

    // MARK: - 3. Threshold live-sync

    func testMonoL1LiveSyncs() {
        let viewModel = WidgetViewModel(settings: settings)
        settings.monologueLevel1Minutes = 2.0
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(viewModel.monoL1Seconds, 120.0, accuracy: 0.001,
            "monoL1Seconds must update when settings.monologueLevel1Minutes changes")
    }

    func testMonoL2LiveSyncs() {
        let viewModel = WidgetViewModel(settings: settings)
        settings.monologueLevel2Minutes = 3.0
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(viewModel.monoL2Seconds, 180.0, accuracy: 0.001,
            "monoL2Seconds must update when settings.monologueLevel2Minutes changes")
    }

    func testMonoL3LiveSyncs() {
        let viewModel = WidgetViewModel(settings: settings)
        settings.monologueLevel3Minutes = 4.0
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(viewModel.monoL3Seconds, 240.0, accuracy: 0.001,
            "monoL3Seconds must update when settings.monologueLevel3Minutes changes")
    }
}
