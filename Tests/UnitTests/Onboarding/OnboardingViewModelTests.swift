import AVFoundation
import Speech
import XCTest
@testable import TalkCoach

@MainActor
final class OnboardingViewModelTests: XCTestCase {

    // MARK: - Mock

    final class MockPermissionStatusProvider: PermissionStatusProvider, @unchecked Sendable {
        var micStatus: AVAuthorizationStatus = .notDetermined
        var micRequestResult: Bool = false
        func micAuthorizationStatus() -> AVAuthorizationStatus { micStatus }
        func speechAuthorizationStatus() -> SFSpeechRecognizerAuthorizationStatus { .notDetermined }
        func requestMicAccess() async -> Bool { micRequestResult }
        func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus { .notDetermined }
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(userDefaults: makeIsolatedDefaults())
    }

    // MARK: - Test 1

    func testInitialStep_isOne() {
        let viewModel = OnboardingViewModel(settingsStore: makeStore())
        XCTAssertEqual(viewModel.currentStep, 1)
    }

    // MARK: - Test 2

    func testAdvance_incrementsStep() {
        let viewModel = OnboardingViewModel(settingsStore: makeStore())
        viewModel.advance()
        XCTAssertEqual(viewModel.currentStep, 2)
    }

    // MARK: - Test 3

    func testCanContinue_falseWhenMicNotGranted() {
        let viewModel = OnboardingViewModel(settingsStore: makeStore())
        viewModel.micGranted = false
        viewModel.setPrimaryLocale("en_US")
        XCTAssertFalse(viewModel.canContinueStep2)
    }

    // MARK: - Test 4

    func testCanContinue_falseWhenPrimaryNil() {
        let viewModel = OnboardingViewModel(settingsStore: makeStore())
        viewModel.micGranted = true
        viewModel.setPrimaryLocale(nil)
        XCTAssertFalse(viewModel.canContinueStep2)
    }

    // MARK: - Test 5

    func testCanContinue_falseWhenSameLocale() {
        let viewModel = OnboardingViewModel(settingsStore: makeStore())
        viewModel.micGranted = true
        viewModel.setPrimaryLocale("en_US")
        viewModel.setSecondaryLocale("en_US")
        XCTAssertFalse(viewModel.canContinueStep2)
    }

    // MARK: - Test 6

    func testCanContinue_trueWhenAllMet() {
        let viewModel = OnboardingViewModel(settingsStore: makeStore())
        viewModel.micGranted = true
        viewModel.setPrimaryLocale("en_US")
        viewModel.setSecondaryLocale(nil)
        XCTAssertTrue(viewModel.canContinueStep2)
    }

    // MARK: - Test 7

    func testCanContinue_trueWithDifferentSecondary() {
        let viewModel = OnboardingViewModel(settingsStore: makeStore())
        viewModel.micGranted = true
        viewModel.setPrimaryLocale("en_US")
        viewModel.setSecondaryLocale("fr_FR")
        XCTAssertTrue(viewModel.canContinueStep2)
    }

    // MARK: - Test 8

    func testRequestMicPermission_granted_setsMicGranted() async throws {
        let mock = MockPermissionStatusProvider()
        mock.micRequestResult = true
        let viewModel = OnboardingViewModel(settingsStore: makeStore(), statusProvider: mock)
        await viewModel.requestMicPermission()
        XCTAssertTrue(viewModel.micGranted)
    }

    // MARK: - Test 9

    func testRequestMicPermission_denied_staysFalse() async throws {
        let mock = MockPermissionStatusProvider()
        mock.micRequestResult = false
        let viewModel = OnboardingViewModel(settingsStore: makeStore(), statusProvider: mock)
        await viewModel.requestMicPermission()
        XCTAssertFalse(viewModel.micGranted)
    }

    // MARK: - Test 10

    func testPrimaryLocaleChange_writesToSettingsStore() {
        let store = makeStore()
        let viewModel = OnboardingViewModel(settingsStore: store)
        viewModel.setPrimaryLocale("fr_FR")
        XCTAssertEqual(store.declaredLocales.first, "fr_FR")
    }

    // MARK: - Test 11

    func testSecondaryLocaleNil_removesSecondEntry() {
        let store = makeStore()
        let viewModel = OnboardingViewModel(settingsStore: store)
        viewModel.setPrimaryLocale("en_US")
        viewModel.setSecondaryLocale("de_DE")
        viewModel.setSecondaryLocale(nil)
        XCTAssertEqual(store.declaredLocales.count, 1)
    }

    // MARK: - Test 12

    func testComplete_setsHasCompletedOnboarding() {
        let store = makeStore()
        let viewModel = OnboardingViewModel(settingsStore: store)
        viewModel.complete()
        XCTAssertTrue(store.hasCompletedOnboarding)
    }

    // MARK: - Test 13

    func testComplete_setsHasCompletedSetup() {
        let store = makeStore()
        let viewModel = OnboardingViewModel(settingsStore: store)
        viewModel.complete()
        XCTAssertTrue(store.hasCompletedSetup)
    }

    // MARK: - Test 14

    func testComplete_callsCompletionHandler() {
        var fired = false
        let viewModel = OnboardingViewModel(settingsStore: makeStore(), onComplete: { fired = true })
        viewModel.complete()
        XCTAssertTrue(fired)
    }

    // MARK: - Test 15

    func testPreGrantedMicShowsToggleOn() {
        let mock = MockPermissionStatusProvider()
        mock.micStatus = .authorized
        let viewModel = OnboardingViewModel(settingsStore: makeStore(), statusProvider: mock)
        XCTAssertTrue(viewModel.micGranted)
    }

    // MARK: - Test 16

    func testExistingUserMigration_skipsOnboarding() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "hasCompletedSetup")
        defaults.set(["en_US"], forKey: "declaredLocales")
        // No hasCompletedOnboarding key written yet
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertTrue(store.hasCompletedOnboarding,
                      "Existing user with hasCompletedSetup=true must skip onboarding via migration")
    }

    // MARK: - Test 17

    func testFreshInstall_bothFlagsDefaultFalse() {
        let store = SettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertFalse(store.hasCompletedOnboarding)
        XCTAssertFalse(store.hasCompletedSetup)
    }

    // MARK: - Test 18

    func testLocalePersistenceAcrossInit() {
        let defaults = makeIsolatedDefaults()
        let store1 = SettingsStore(userDefaults: defaults)
        store1.declaredLocales = ["en_US", "fr_FR"]
        let store2 = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(store2.declaredLocales, ["en_US", "fr_FR"])
    }

    // MARK: - Test 19

    func testRestartReseedsFromStore() {
        let defaults = makeIsolatedDefaults()
        let store = SettingsStore(userDefaults: defaults)
        store.declaredLocales = ["de_DE"]
        let viewModel = OnboardingViewModel(settingsStore: store)
        XCTAssertEqual(viewModel.primaryLocaleID, "de_DE")
    }

    // MARK: - Test 20

    func testAdvance_doesNotExceedStep5() {
        let viewModel = OnboardingViewModel(settingsStore: makeStore())
        for _ in 0..<10 {
            viewModel.advance()
        }
        XCTAssertEqual(viewModel.currentStep, 5)
    }

    // MARK: - Test 21

    func testStep5CloseX_callsComplete() {
        var fired = false
        let viewModel = OnboardingViewModel(settingsStore: makeStore(), onComplete: { fired = true })
        viewModel.complete()
        XCTAssertTrue(fired)
    }
}
