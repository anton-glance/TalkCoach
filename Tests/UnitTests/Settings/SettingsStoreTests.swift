import XCTest
@testable import TalkCoach

@MainActor
final class SettingsStoreTests: XCTestCase {

    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    }

    // MARK: - Default value tests

    func testCoachingEnabledDefaultsToTrue() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertTrue(store.coachingEnabled)
    }

    func testDeclaredLocalesDefaultsToEmptyOnFreshInstall() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertEqual(store.declaredLocales, [],
                       "Fresh install: onboarding owns first locale selection")
    }

    func testHasCompletedSetupDefaultsToFalseOnFreshInstall() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertFalse(store.hasCompletedSetup,
                       "Fresh install: setup is not complete until onboarding finishes")
    }

    func testHasCompletedOnboardingDefaultsFalseForFreshInstall() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertFalse(store.hasCompletedOnboarding,
                       "Fresh install: onboarding has not been completed")
    }

    func testHasCompletedOnboardingMigrationFromExistingUser() {
        let defaults = makeIsolatedDefaults()
        // Simulate existing user: hasCompletedSetup=true, no hasCompletedOnboarding key
        defaults.set(true, forKey: "hasCompletedSetup")
        defaults.set(["en_US"], forKey: "declaredLocales")
        // No hasCompletedOnboarding key written yet

        let store = SettingsStore(userDefaults: defaults)
        XCTAssertTrue(store.hasCompletedOnboarding,
                      "Existing user with hasCompletedSetup=true must skip onboarding via migration")
    }

    func testHasCompletedOnboardingWriteThenRead() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.hasCompletedOnboarding = true
        XCTAssertTrue(store.hasCompletedOnboarding)
    }

    func testWidgetPositionByDisplayDefaultsToEmpty() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertEqual(store.widgetPositionByDisplay, [:])
    }

    // MARK: - Write-then-read tests

    func testWriteThenReadCoachingEnabled() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.coachingEnabled = false
        XCTAssertFalse(store.coachingEnabled)
        store.coachingEnabled = true
        XCTAssertTrue(store.coachingEnabled)
    }

    func testWriteThenReadDeclaredLocales() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.declaredLocales = ["en_US", "ru_RU"]
        XCTAssertEqual(store.declaredLocales, ["en_US", "ru_RU"])
    }

    func testWriteThenReadWidgetPositionByDisplay() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        let positions = ["Built-in Display": CGPoint(x: 100, y: 200)]
        store.widgetPositionByDisplay = positions
        XCTAssertEqual(store.widgetPositionByDisplay["Built-in Display"]?.x, 100)
        XCTAssertEqual(store.widgetPositionByDisplay["Built-in Display"]?.y, 200)
    }

    // MARK: - Cross-component contract

    func testCoachingEnabledKeyMatchesAppStorage() {
        UserDefaults.standard.removeObject(forKey: "coachingEnabled")
        let store = SettingsStore(userDefaults: UserDefaults.standard)
        XCTAssertTrue(store.coachingEnabled)

        store.coachingEnabled = false
        let rawValue = UserDefaults.standard.object(forKey: "coachingEnabled") as? Bool
        XCTAssertEqual(rawValue, false)

        UserDefaults.standard.removeObject(forKey: "coachingEnabled")
    }

    // MARK: - Live sync from external writes

    func testCoachingEnabledUpdatesWhenWrittenExternally() {
        let defaults = makeIsolatedDefaults()
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertTrue(store.coachingEnabled)

        defaults.set(false, forKey: "coachingEnabled")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertFalse(store.coachingEnabled)
    }

    // MARK: - Last-used display

    func testLastUsedDisplayDefaultsToNil() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertNil(store.lastUsedDisplay())
    }

    func testLastUsedDisplayRoundTrips() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.setLastUsedDisplay("External Monitor")
        XCTAssertEqual(store.lastUsedDisplay(), "External Monitor")
    }

    func testLastUsedDisplayPersistsAcrossInstances() {
        let defaults = makeIsolatedDefaults()
        let store1 = SettingsStore(userDefaults: defaults)
        store1.setLastUsedDisplay("External Monitor")

        let store2 = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(
            store2.lastUsedDisplay(), "External Monitor",
            "Value must survive across SettingsStore instances"
        )
    }

    // MARK: - M4.1: wpmEmaAlpha

    func testWpmEmaAlphaDefaultsTo0_70() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertEqual(store.wpmEmaAlpha, 0.70, accuracy: 0.001)
    }

    func testWpmEmaAlphaClampedToMin0_1() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.wpmEmaAlpha = 0.0
        XCTAssertEqual(store.wpmEmaAlpha, 0.1, accuracy: 0.001)
    }

    func testWpmEmaAlphaClampedToMax1_0() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.wpmEmaAlpha = 1.5
        XCTAssertEqual(store.wpmEmaAlpha, 1.0, accuracy: 0.001)
    }

    // MARK: - M4.4: waitingOpacity

    func testWaitingOpacityDefaultsTo0_5() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertEqual(store.waitingOpacity, 0.5, accuracy: 0.001)
    }

    func testWaitingOpacityClampedToMin0_1() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.waitingOpacity = 0.0
        XCTAssertEqual(store.waitingOpacity, 0.1, accuracy: 0.001)
    }

    func testWaitingOpacityClampedToMax1_0() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.waitingOpacity = 1.5
        XCTAssertEqual(store.waitingOpacity, 1.0, accuracy: 0.001)
    }

    // MARK: - M4.4: lingerFullSeconds

    func testLingerFullSecondsDefaultsTo3_0() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertEqual(store.lingerFullSeconds, 3.0, accuracy: 0.001)
    }

    func testLingerFullSecondsClampedToMin1_0() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.lingerFullSeconds = 0.5
        XCTAssertEqual(store.lingerFullSeconds, 1.0, accuracy: 0.001)
    }

    func testLingerFullSecondsClampedToMax10_0() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.lingerFullSeconds = 11.0
        XCTAssertEqual(store.lingerFullSeconds, 10.0, accuracy: 0.001)
    }

    // MARK: - M4.4: lingerFadeSeconds

    func testLingerFadeSecondsDefaultsTo2_0() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertEqual(store.lingerFadeSeconds, 2.0, accuracy: 0.001)
    }

    func testLingerFadeSecondsClampedToMin0_5() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.lingerFadeSeconds = 0.1
        XCTAssertEqual(store.lingerFadeSeconds, 0.5, accuracy: 0.001)
    }

    func testLingerFadeSecondsClampedToMax5_0() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.lingerFadeSeconds = 6.0
        XCTAssertEqual(store.lingerFadeSeconds, 5.0, accuracy: 0.001)
    }

    // MARK: - M4.4: recoveryGraceSeconds

    func testRecoveryGraceSecondsDefaultsTo2_0() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertEqual(store.recoveryGraceSeconds, 2.0, accuracy: 0.001)
    }

    func testRecoveryGraceSecondsClampedToMin0_5() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.recoveryGraceSeconds = 0.1
        XCTAssertEqual(store.recoveryGraceSeconds, 0.5, accuracy: 0.001)
    }

    func testRecoveryGraceSecondsClampedToMax5_0() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.recoveryGraceSeconds = 6.0
        XCTAssertEqual(store.recoveryGraceSeconds, 5.0, accuracy: 0.001)
    }
}
