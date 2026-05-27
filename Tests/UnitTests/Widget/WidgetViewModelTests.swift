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
        let vm = WidgetViewModel(settings: settings)
        XCTAssertEqual(vm.streakSeconds, 0, "streakSeconds must default to 0")
    }

    func testWidgetViewModelHasMonoL1Seconds() {
        let vm = WidgetViewModel(settings: settings)
        XCTAssertEqual(vm.monoL1Seconds, settings.monologueLevel1Minutes * 60, accuracy: 0.001,
            "monoL1Seconds must mirror settings default (L1 in seconds)")
    }

    func testWidgetViewModelHasMonoL2Seconds() {
        let vm = WidgetViewModel(settings: settings)
        XCTAssertEqual(vm.monoL2Seconds, settings.monologueLevel2Minutes * 60, accuracy: 0.001,
            "monoL2Seconds must mirror settings default (L2 in seconds)")
    }

    func testWidgetViewModelHasMonoL3Seconds() {
        let vm = WidgetViewModel(settings: settings)
        XCTAssertEqual(vm.monoL3Seconds, settings.monologueLevel3Minutes * 60, accuracy: 0.001,
            "monoL3Seconds must mirror settings default (L3 in seconds)")
    }

    func testWidgetViewModelHasMonoPauseSeconds() {
        let vm = WidgetViewModel(settings: settings)
        XCTAssertEqual(vm.monoPauseSeconds, settings.wpmPauseThreshold, accuracy: 0.001,
            "monoPauseSeconds must mirror settings.wpmPauseThreshold default")
    }

    // MARK: - 2. isIdle derivation

    func testIsIdleWhenActivityStateNotCounting() {
        let vm = WidgetViewModel(settings: settings)
        vm.activityState = .waiting
        vm.currentWPMVoiced = 130
        XCTAssertTrue(vm.isIdle,
            "isIdle must be true when activityState != .counting, regardless of WPM")
    }

    func testIsIdleWhenWPMNil() {
        let vm = WidgetViewModel(settings: settings)
        vm.activityState = .counting
        vm.currentWPMVoiced = nil
        XCTAssertTrue(vm.isIdle,
            "isIdle must be true when counting but WPM is nil (calculator hasn't fired yet)")
    }

    func testIsActiveWhenCountingAndWPMPresent() {
        let vm = WidgetViewModel(settings: settings)
        vm.activityState = .counting
        vm.currentWPMVoiced = 120
        XCTAssertFalse(vm.isIdle,
            "isIdle must be false when activityState == .counting AND WPM is non-nil")
    }

    // MARK: - 3. Threshold live-sync

    func testMonoL1LiveSyncs() {
        let vm = WidgetViewModel(settings: settings)
        settings.monologueLevel1Minutes = 2.0
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(vm.monoL1Seconds, 120.0, accuracy: 0.001,
            "monoL1Seconds must update when settings.monologueLevel1Minutes changes")
    }

    func testMonoL2LiveSyncs() {
        let vm = WidgetViewModel(settings: settings)
        settings.monologueLevel2Minutes = 3.0
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(vm.monoL2Seconds, 180.0, accuracy: 0.001,
            "monoL2Seconds must update when settings.monologueLevel2Minutes changes")
    }

    func testMonoL3LiveSyncs() {
        let vm = WidgetViewModel(settings: settings)
        settings.monologueLevel3Minutes = 4.0
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(vm.monoL3Seconds, 240.0, accuracy: 0.001,
            "monoL3Seconds must update when settings.monologueLevel3Minutes changes")
    }
}
