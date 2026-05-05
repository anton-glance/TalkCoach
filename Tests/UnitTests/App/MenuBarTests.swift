import XCTest
@testable import TalkCoach

@MainActor
final class MenuBarTests: XCTestCase {

    private let coachingKey = "coachingEnabled"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: coachingKey)
        super.tearDown()
    }

    // MARK: - Coaching enabled default

    func testCoachingEnabledDefaultsToTrue() {
        UserDefaults.standard.removeObject(forKey: coachingKey)
        let stored = UserDefaults.standard.object(forKey: coachingKey)
        XCTAssertNil(stored, "coachingEnabled should not be set by default")
        XCTAssertEqual(
            pauseResumeMenuTitle(coachingEnabled: true),
            "Pause Coaching",
            "Default-true path must produce 'Pause Coaching'"
        )
    }

    // MARK: - Toggle round-trip

    func testToggleCoachingEnabledFlipsValue() {
        let defaults = UserDefaults.standard

        defaults.set(true, forKey: coachingKey)
        XCTAssertTrue(defaults.bool(forKey: coachingKey))

        let current = defaults.bool(forKey: coachingKey)
        defaults.set(!current, forKey: coachingKey)
        XCTAssertFalse(defaults.bool(forKey: coachingKey))

        let flipped = defaults.bool(forKey: coachingKey)
        defaults.set(!flipped, forKey: coachingKey)
        XCTAssertTrue(defaults.bool(forKey: coachingKey))
    }

    // MARK: - Menu title reflects state

    func testMenuTitleReflectsCoachingState() {
        XCTAssertEqual(
            pauseResumeMenuTitle(coachingEnabled: true),
            "Pause Coaching"
        )
        XCTAssertEqual(
            pauseResumeMenuTitle(coachingEnabled: false),
            "Resume Coaching"
        )
    }

    // MARK: - Settings window contract

    func testSettingsWindowOpenedViaAppDelegateOpenSettings() {
        let delegate = AppDelegate()
        delegate.openSettings()
        XCTAssertNotNil(delegate.settingsWindow)
        XCTAssertTrue(delegate.settingsWindow?.isVisible == true)
        delegate.settingsWindow?.close()
    }

    // MARK: - App body smoke test

    func testTalkCoachAppBodyDoesNotThrow() {
        let app = TalkCoachApp()
        _ = app.body
    }
}
