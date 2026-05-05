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
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertFalse(store.hasCompletedSetup)
        XCTAssertTrue(store.declaredLocales.isEmpty)

        store.toggleLocale("en_US")

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
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertTrue(store.declaredLocales.isEmpty)
        XCTAssertFalse(store.hasCompletedSetup)

        store.commitSystemLocaleIfApplicable(systemLocaleIdentifier: "en_US")

        XCTAssertEqual(store.declaredLocales, ["en_US"])
        XCTAssertTrue(store.hasCompletedSetup)
    }

    func testFirstLaunchDoesNothingWhenSystemLocaleNotInRegistry() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertTrue(store.declaredLocales.isEmpty)
        XCTAssertFalse(store.hasCompletedSetup)

        store.commitSystemLocaleIfApplicable(systemLocaleIdentifier: "ka_GE")

        XCTAssertTrue(store.declaredLocales.isEmpty)
        XCTAssertFalse(store.hasCompletedSetup)
    }
}
