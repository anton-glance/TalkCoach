// swiftlint:disable file_length
// TODO: FloatingPanelController test fixtures create real NSPanel windows that are not torn down
// between test cases. Leftover panels remain on screen after the test suite runs. Fix scope is
// too broad for a corrective sub-commit — defer to a dedicated test-hygiene pass. If you see
// stray Locto widget squares after running tests, dismiss them manually.
import Combine
import CoreAudio
import XCTest
@testable import TalkCoach

private final class FakeCoreAudioDeviceProvider: CoreAudioDeviceProvider, @unchecked Sendable {
    nonisolated(unsafe) var stubbedDefaultDeviceID: AudioObjectID? = 42
    nonisolated(unsafe) var stubbedIsRunning: Bool = false
    nonisolated(unsafe) private(set) var isRunningHandler: (@Sendable () -> Void)?
    private final class Token {}
    nonisolated func defaultInputDeviceID() -> AudioObjectID? { stubbedDefaultDeviceID }
    nonisolated func isDeviceRunningSomewhere(_ deviceID: AudioObjectID) -> Bool? { stubbedIsRunning }
    nonisolated func addIsRunningListener(
        device: AudioObjectID, handler: @escaping @Sendable () -> Void
    ) -> AnyObject? { isRunningHandler = handler; return Token() }
    nonisolated func removeIsRunningListener(device: AudioObjectID, token: AnyObject) {}
    nonisolated func addDefaultDeviceListener(
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject? { Token() }
    nonisolated func removeDefaultDeviceListener(token: AnyObject) {}
    func simulateIsRunningChange() { isRunningHandler?() }
}

private final class FakeAlertPresenter: AlertPresenter, @unchecked Sendable {
    nonisolated(unsafe) var stubbedResult: Bool = false
    nonisolated(unsafe) private(set) var presentCallCount = 0

    @MainActor func presentDismissConfirmation() -> Bool {
        presentCallCount += 1
        return stubbedResult
    }
}

private final class FakeHideScheduler: HideScheduler, @unchecked Sendable {
    nonisolated(unsafe) private(set) var scheduledAction: (@MainActor @Sendable () -> Void)?
    nonisolated(unsafe) private(set) var scheduledDelay: TimeInterval?
    nonisolated(unsafe) private(set) var cancelCallCount = 0
    @MainActor func schedule(
        delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void
    ) -> HideSchedulerToken {
        scheduledDelay = delay
        scheduledAction = action
        return HideSchedulerToken()
    }
    @MainActor func cancel(_ token: HideSchedulerToken) { cancelCallCount += 1; scheduledAction = nil }
    @MainActor func fire() { scheduledAction?(); scheduledAction = nil }
}

// MARK: - Tests

@MainActor
// swiftlint:disable:next type_body_length
final class FloatingPanelControllerTests: XCTestCase {

    private var fake: FakeCoreAudioDeviceProvider!
    private var fakeAlert: FakeAlertPresenter!
    private var fakeScheduler: FakeHideScheduler!
    private var settingsStore: SettingsStore!
    private var defaults: UserDefaults!
    private var coordinator: SessionCoordinator!
    private var sut: FloatingPanelController!

    private func makeSUT(coachingEnabled: Bool = true) {
        defaults = UserDefaults(suiteName: "FloatingPanelTests.\(name)")!
        defaults.removePersistentDomain(forName: "FloatingPanelTests.\(name)")
        defaults.set(coachingEnabled, forKey: "coachingEnabled")
        settingsStore = SettingsStore(userDefaults: defaults)
        fake = FakeCoreAudioDeviceProvider()
        fake.stubbedDefaultDeviceID = 42
        fake.stubbedIsRunning = false
        fakeAlert = FakeAlertPresenter()
        fakeScheduler = FakeHideScheduler()
        let micMonitor = MicMonitor(provider: fake)
        coordinator = SessionCoordinator(micMonitor: micMonitor, settingsStore: settingsStore)
        sut = FloatingPanelController(
            sessionCoordinator: coordinator,
            alertPresenter: fakeAlert,
            hideScheduler: fakeScheduler,
            settingsStore: settingsStore,
            reducedMotionProvider: { true }
        )
    }

    private func activateMic() async {
        fake.stubbedIsRunning = true
        fake.simulateIsRunningChange()
        await Task.yield()
    }

    private func deactivateMic() async {
        fake.stubbedIsRunning = false
        fake.simulateIsRunningChange()
        await Task.yield()
    }

    // MARK: - Initial state

    func testInitialStateIsHiddenWhenIdle() {
        makeSUT()
        sut.start()
        coordinator.start()
        XCTAssertEqual(sut.panelState, .hidden)
        XCTAssertFalse(sut.isShowingPanel)
    }

    // MARK: - Visible on mic-on (warming), counting on engine-ready (AC-FIX7)

    func testMicActivation_ShowsWarming_CountingOnEngineReady() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()

        XCTAssertEqual(sut.panelState, .visible,
                       "Widget must appear immediately on mic-on in .warming state (AC-FIX7)")
        XCTAssertTrue(sut.isShowingPanel)
        XCTAssertEqual(sut.viewModel.activityState, .warming,
                       "activityState must be .warming on mic-on (AC-FIX7)")

        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        XCTAssertEqual(sut.panelState, .visible)
        XCTAssertEqual(sut.viewModel.activityState, .counting,
                       "activityState must transition to .counting on engine-ready")
    }

    // MARK: - Idempotent visible state

    func testStayVisibleOnReemittedActiveState() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()

        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.panelState, .visible)

        fake.simulateIsRunningChange()
        await Task.yield()

        XCTAssertEqual(sut.panelState, .visible)
        XCTAssertTrue(sut.isShowingPanel)
    }

    // MARK: - Session end while warming starts lingerFull

    func testSessionEnd_WhileWarming_StartsLingerFull() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        XCTAssertEqual(sut.panelState, .visible, "Panel must be .visible (warming) after mic-on")

        await deactivateMic()

        // AC-FIX7: panel shows at mic-on, so session-end while warming → lingerFull
        XCTAssertEqual(sut.panelState, .lingerFull,
                       "Session end while visible (warming) must start lingerFull (AC-FIX7)")
    }

    // MARK: - Phase G: rapid reactivation during linger

    func testPhaseG_RapidReactivation_DuringLingerFull() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        XCTAssertEqual(sut.panelState, .visible, "Panel visible (warming) after first mic-on")
        await deactivateMic()
        XCTAssertEqual(sut.panelState, .lingerFull, "Session end while warming → lingerFull")

        // Rapid reactivation during lingerFull (Phase G)
        await activateMic()
        // Panel stays in linger until engine-ready
        XCTAssertEqual(sut.panelState, .lingerFull,
                       "Phase G: panel must stay in lingerFull between mic-on and engine-ready")

        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.panelState, .visible,
                       "Phase G: engine-ready during lingerFull must transition to .visible")
    }

    // MARK: - Dismiss confirmation

    func testDismissConfirmYesHidesImmediately() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        fakeAlert.stubbedResult = true

        sut.requestDismiss()

        XCTAssertEqual(fakeAlert.presentCallCount, 1)
        XCTAssertEqual(sut.panelState, .dismissed)
        XCTAssertFalse(sut.isShowingPanel)
        XCTAssertEqual(coordinator.state, .idle, "Coordinator must finalize session on X-button dismiss (B1 fix)")
    }

    func testDismissConfirmNoKeepsVisible() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        fakeAlert.stubbedResult = false

        sut.requestDismiss()

        XCTAssertEqual(fakeAlert.presentCallCount, 1)
        XCTAssertEqual(sut.panelState, .visible)
        XCTAssertTrue(sut.isShowingPanel)
    }

    // MARK: - Dismissal scope clears on session end

    func testDismissalScopeClearsOnSessionEnd() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        fakeAlert.stubbedResult = true
        sut.requestDismiss()
        XCTAssertEqual(sut.panelState, .dismissed)

        await deactivateMic()
        XCTAssertEqual(sut.panelState, .dismissed)

        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.panelState, .visible)
        XCTAssertTrue(sut.isShowingPanel, "Panel must re-appear after dismissal scope clears")
    }

    // MARK: - Pause mid-session uses fade timer

    func testPauseMidSessionUsesFadeTimer() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.panelState, .visible)

        settingsStore.coachingEnabled = false
        await Task.yield()

        // M3.7.3-fix6: session-end while visible starts lingerFull (3-second stay before fade)
        XCTAssertEqual(sut.panelState, .lingerFull,
                       "M3.7.3-fix6: coaching-disabled session end while visible must start lingerFull")
    }

    // MARK: - Lifecycle idempotency

    func testStartIdempotent() async {
        makeSUT()
        sut.start()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        XCTAssertEqual(sut.panelState, .visible)

        await deactivateMic()
        fakeScheduler.fire()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        XCTAssertEqual(sut.panelState, .visible, "Only one observation path — no double show")
    }

    func testStopWhileVisibleHidesImmediately() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertTrue(sut.isShowingPanel)

        sut.stop()

        XCTAssertEqual(sut.panelState, .hidden)
        XCTAssertFalse(sut.isShowingPanel)
    }

    func testStopIdempotent() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        sut.stop()
        sut.stop()
        XCTAssertEqual(sut.panelState, .hidden)
    }

    // MARK: - Stop cancels pending hide timer

    func testStopCancelsPendingHideTimer() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        XCTAssertEqual(sut.panelState, .visible, "Panel visible (warming) after mic-on")
        await deactivateMic()
        XCTAssertEqual(sut.panelState, .lingerFull, "Session end while warming → lingerFull")

        sut.stop()
        XCTAssertEqual(sut.panelState, .hidden)

        fakeScheduler.fire()
        XCTAssertEqual(sut.panelState, .hidden, "Fired timer after stop must be no-op")
    }

    // MARK: - Rapid toggle sequence

    func testRapidIdleActiveIdleActiveSequence() async {
        makeSUT()
        sut.start()
        coordinator.start()

        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.panelState, .visible)

        await deactivateMic()
        // M3.7.3-fix6: session-end while visible → lingerFull
        XCTAssertEqual(sut.panelState, .lingerFull,
                       "M3.7.3-fix6: session end while visible must start lingerFull")

        // Fire lingerFull timer → reducedMotion=true → handleLingerFadeCompleted → .hidden
        fakeScheduler.fire()
        XCTAssertEqual(sut.panelState, .hidden)

        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.panelState, .visible)

        await deactivateMic()
        XCTAssertEqual(sut.panelState, .lingerFull,
                       "M3.7.3-fix6: second session end while visible must also start lingerFull")

        fakeScheduler.fire()
        XCTAssertEqual(sut.panelState, .hidden)
    }

    // MARK: - Dismiss while hidden is no-op

    func testDismissWhileHiddenIsNoOp() {
        makeSUT()
        sut.start()
        coordinator.start()
        // Never activate — panel stays .hidden

        fakeAlert.stubbedResult = true
        sut.requestDismiss()

        XCTAssertEqual(fakeAlert.presentCallCount, 0, "Alert must not present when hidden")
        XCTAssertEqual(sut.panelState, .hidden)
    }

    // MARK: - Deallocation

    func testDeallocation() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()

        weak var weakController = sut
        sut.stop()
        sut = nil

        fakeScheduler.fire()

        XCTAssertNil(weakController, "Controller must deallocate after stop and release")
    }

    // MARK: - Start after stop resumes observation

    func testStartAfterStopResumesObservation() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        sut.stop()
        XCTAssertEqual(sut.panelState, .hidden)

        sut.start()
        await deactivateMic()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.panelState, .visible)
    }

    // MARK: - VAD-driven waiting state (Architecture Z, sub-commit 3)

    func testIsVoiceInactiveTriggersWaitingState() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .counting, "precondition: must be counting")

        coordinator.isVoiceInactive = true
        await Task.yield()

        XCTAssertEqual(
            sut.viewModel.activityState, .waiting,
            "VAD voice-inactive signal must transition widget to .waiting"
        )
    }
}
