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
        let vm = OnboardingViewModel(settingsStore: makeStore())
        XCTAssertEqual(vm.currentStep, 1)
    }

    // MARK: - Test 2

    func testAdvance_incrementsStep() {
        let vm = OnboardingViewModel(settingsStore: makeStore())
        vm.advance()
        XCTAssertEqual(vm.currentStep, 2)
    }

    // MARK: - Test 3

    func testCanContinue_falseWhenMicNotGranted() {
        let vm = OnboardingViewModel(settingsStore: makeStore())
        vm.micGranted = false
        vm.setPrimaryLocale("en_US")
        XCTAssertFalse(vm.canContinueStep2)
    }

    // MARK: - Test 4

    func testCanContinue_falseWhenPrimaryNil() {
        let vm = OnboardingViewModel(settingsStore: makeStore())
        vm.micGranted = true
        vm.setPrimaryLocale(nil)
        XCTAssertFalse(vm.canContinueStep2)
    }

    // MARK: - Test 5

    func testCanContinue_falseWhenSameLocale() {
        let vm = OnboardingViewModel(settingsStore: makeStore())
        vm.micGranted = true
        vm.setPrimaryLocale("en_US")
        vm.setSecondaryLocale("en_US")
        XCTAssertFalse(vm.canContinueStep2)
    }

    // MARK: - Test 6

    func testCanContinue_trueWhenAllMet() {
        let vm = OnboardingViewModel(settingsStore: makeStore())
        vm.micGranted = true
        vm.setPrimaryLocale("en_US")
        vm.setSecondaryLocale(nil)
        XCTAssertTrue(vm.canContinueStep2)
    }

    // MARK: - Test 7

    func testCanContinue_trueWithDifferentSecondary() {
        let vm = OnboardingViewModel(settingsStore: makeStore())
        vm.micGranted = true
        vm.setPrimaryLocale("en_US")
        vm.setSecondaryLocale("fr_FR")
        XCTAssertTrue(vm.canContinueStep2)
    }

    // MARK: - Test 8

    func testRequestMicPermission_granted_setsMicGranted() async throws {
        let mock = MockPermissionStatusProvider()
        mock.micRequestResult = true
        let vm = OnboardingViewModel(settingsStore: makeStore(), statusProvider: mock)
        await vm.requestMicPermission()
        XCTAssertTrue(vm.micGranted)
    }

    // MARK: - Test 9

    func testRequestMicPermission_denied_staysFalse() async throws {
        let mock = MockPermissionStatusProvider()
        mock.micRequestResult = false
        let vm = OnboardingViewModel(settingsStore: makeStore(), statusProvider: mock)
        await vm.requestMicPermission()
        XCTAssertFalse(vm.micGranted)
    }

    // MARK: - Test 10

    func testPrimaryLocaleChange_writesToSettingsStore() {
        let store = makeStore()
        let vm = OnboardingViewModel(settingsStore: store)
        vm.setPrimaryLocale("fr_FR")
        XCTAssertEqual(store.declaredLocales.first, "fr_FR")
    }

    // MARK: - Test 11

    func testSecondaryLocaleNil_removesSecondEntry() {
        let store = makeStore()
        let vm = OnboardingViewModel(settingsStore: store)
        vm.setPrimaryLocale("en_US")
        vm.setSecondaryLocale("de_DE")
        vm.setSecondaryLocale(nil)
        XCTAssertEqual(store.declaredLocales.count, 1)
    }

    // MARK: - Test 12

    func testComplete_setsHasCompletedOnboarding() {
        let store = makeStore()
        let vm = OnboardingViewModel(settingsStore: store)
        vm.complete()
        XCTAssertTrue(store.hasCompletedOnboarding)
    }

    // MARK: - Test 13

    func testComplete_setsHasCompletedSetup() {
        let store = makeStore()
        let vm = OnboardingViewModel(settingsStore: store)
        vm.complete()
        XCTAssertTrue(store.hasCompletedSetup)
    }

    // MARK: - Test 14

    func testComplete_callsCompletionHandler() {
        var fired = false
        let vm = OnboardingViewModel(settingsStore: makeStore(), onComplete: { fired = true })
        vm.complete()
        XCTAssertTrue(fired)
    }

    // MARK: - Test 15

    func testPreGrantedMicShowsToggleOn() {
        let mock = MockPermissionStatusProvider()
        mock.micStatus = .authorized
        let vm = OnboardingViewModel(settingsStore: makeStore(), statusProvider: mock)
        XCTAssertTrue(vm.micGranted)
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
        let vm = OnboardingViewModel(settingsStore: store)
        XCTAssertEqual(vm.primaryLocaleID, "de_DE")
    }

    // MARK: - Test 20

    func testAdvance_doesNotExceedStep5() {
        let vm = OnboardingViewModel(settingsStore: makeStore())
        for _ in 0..<10 {
            vm.advance()
        }
        XCTAssertEqual(vm.currentStep, 5)
    }

    // MARK: - Test 21

    func testStep5CloseX_callsComplete() {
        var fired = false
        let vm = OnboardingViewModel(settingsStore: makeStore(), onComplete: { fired = true })
        vm.complete()
        XCTAssertTrue(fired)
    }
}
