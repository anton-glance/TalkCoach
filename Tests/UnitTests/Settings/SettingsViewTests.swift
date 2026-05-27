import XCTest
@testable import TalkCoach

@MainActor
final class SettingsViewTests: XCTestCase {

    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    }

    // MARK: - Auto-open decision

    func testShouldAutoOpenSettingsOnFirstLaunch() {
        XCTAssertTrue(shouldAutoOpenSettings(hasCompletedSetup: false))
    }

    func testShouldNotAutoOpenSettingsAfterSetup() {
        XCTAssertFalse(shouldAutoOpenSettings(hasCompletedSetup: true))
    }

    // MARK: - Locale toggle behavior

    func testFirstSelectionSetsHasCompletedSetup() {
        // v1 locale lock: fresh store starts with en_US selected and setup already complete.
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertTrue(store.hasCompletedSetup)
        XCTAssertEqual(store.declaredLocales, ["en_US"])
    }

    func testRemovingAllLocalesDoesNotResetHasCompletedSetup() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.declaredLocales = ["en_US"]
        store.hasCompletedSetup = true

        store.toggleLocale("en_US")

        XCTAssertTrue(store.declaredLocales.isEmpty)
        XCTAssertTrue(store.hasCompletedSetup)
    }

    func testCannotSelectMoreThanTwoLocales() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.declaredLocales = ["en_US", "ru_RU"]
        store.hasCompletedSetup = true

        store.toggleLocale("es_ES")

        XCTAssertEqual(store.declaredLocales.count, 2)
        XCTAssertEqual(store.declaredLocales, ["en_US", "ru_RU"])
    }

    // MARK: - Silent system-locale commit

    func testFirstLaunchSilentCommitsSystemLocaleWhenSupported() {
        // v1 locale lock: hasCompletedSetup starts true, so commitSystemLocaleIfApplicable
        // is always a no-op — its guard fires immediately.
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.commitSystemLocaleIfApplicable(systemLocaleIdentifier: "en_US")
        XCTAssertEqual(store.declaredLocales, ["en_US"])
        XCTAssertTrue(store.hasCompletedSetup)
    }

    func testFirstLaunchDoesNothingWhenSystemLocaleNotInRegistry() {
        // v1 locale lock: commitSystemLocaleIfApplicable is always a no-op (setup starts complete).
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.commitSystemLocaleIfApplicable(systemLocaleIdentifier: "ka_GE")
        XCTAssertEqual(store.declaredLocales, ["en_US"])
        XCTAssertTrue(store.hasCompletedSetup)
    }
}
