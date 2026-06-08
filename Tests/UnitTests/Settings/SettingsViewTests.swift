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
        // M6.11: fresh store starts empty; onboarding owns first locale selection.
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertFalse(store.hasCompletedSetup,
                       "M6.11: fresh install setup not complete until onboarding finishes")
        XCTAssertEqual(store.declaredLocales, [],
                       "M6.11: fresh install locale list is empty until onboarding sets it")
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
        // M6.11: commitSystemLocaleIfApplicable is a no-op; onboarding handles first locale.
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.commitSystemLocaleIfApplicable(systemLocaleIdentifier: "en_US")
        XCTAssertEqual(store.declaredLocales, [],
                       "M6.11: commitSystemLocaleIfApplicable is a no-op; locales stay empty")
        XCTAssertFalse(store.hasCompletedSetup,
                       "M6.11: hasCompletedSetup stays false until onboarding completes")
    }

    func testFirstLaunchDoesNothingWhenSystemLocaleNotInRegistry() {
        // M6.11: commitSystemLocaleIfApplicable is always a no-op.
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        store.commitSystemLocaleIfApplicable(systemLocaleIdentifier: "ka_GE")
        XCTAssertEqual(store.declaredLocales, [],
                       "M6.11: commitSystemLocaleIfApplicable is a no-op; locales stay empty")
        XCTAssertFalse(store.hasCompletedSetup,
                       "M6.11: hasCompletedSetup stays false until onboarding completes")
    }
}
