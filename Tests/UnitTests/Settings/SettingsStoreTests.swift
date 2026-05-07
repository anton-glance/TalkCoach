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

    func testWPMTargetMinDefaultsTo130() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertEqual(store.wpmTargetMin, 130)
    }

    func testWPMTargetMaxDefaultsTo170() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertEqual(store.wpmTargetMax, 170)
    }

    func testHasCompletedSetupDefaultsToFalse() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertFalse(store.hasCompletedSetup)
    }

    func testDeclaredLocalesDefaultsToEmpty() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertEqual(store.declaredLocales, [])
    }

    func testFillerDictDefaultsToEmpty() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertEqual(store.fillerDict, [:])
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

    func testWriteThenReadWPMTargetMin() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.wpmTargetMin = 100
        XCTAssertEqual(store.wpmTargetMin, 100)
    }

    func testWriteThenReadFillerDict() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        let dict = ["en_US": ["um", "so"], "ru_RU": ["ну"]]
        store.fillerDict = dict
        XCTAssertEqual(store.fillerDict, dict)
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
}
