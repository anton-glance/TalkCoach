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

private final class WPMTestScheduler: HideScheduler, @unchecked Sendable {
    nonisolated(unsafe) private(set) var lastAction: (@MainActor @Sendable () -> Void)?
    @MainActor func schedule(
        delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void
    ) -> HideSchedulerToken {
        lastAction = action
        return HideSchedulerToken()
    }
    @MainActor func cancel(_ token: HideSchedulerToken) { lastAction = nil }
    @MainActor func fireNext() { lastAction?(); lastAction = nil }
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
        // Linger is cancelled immediately at mic-on — panel is warming before engine-ready
        XCTAssertEqual(sut.panelState, .visible,
                       "Phase G: mic-on during lingerFull must cancel linger and show .visible immediately")

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
        XCTAssertEqual(sut.viewModel.activityState, .counting,
            "widget must stay .counting during 2s silence hold")

        fakeScheduler.fire()  // advance 2s hold timer

        XCTAssertEqual(
            sut.viewModel.activityState, .waiting,
            "VAD voice-inactive signal must transition widget to .waiting after 2s hold"
        )
    }

    // MARK: - Gate hold timer and token-override guard (M3.7.6 fix)

    /// Gate speechStopped + hold fires → token arrives → widget STAYS in .waiting.
    /// RED fails because handleTokenArrival() unconditionally sets .counting.
    func testTokenArrivalDoesNotOverrideWaitingState() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .counting, "precondition")

        coordinator.isVoiceInactive = true
        await Task.yield()
        fakeScheduler.fire()  // advance hold timer → .waiting
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .waiting, "must reach .waiting before token test")

        coordinator.lastTokenArrival = Date()
        await Task.yield()

        XCTAssertEqual(sut.viewModel.activityState, .waiting,
            "token arrival must NOT override gate .waiting state")
    }

    /// Gate speechStopped then speechStarted within 2s — timer cancelled, widget stays .counting.
    /// RED fails because isVoiceInactive=true immediately sets .waiting (no hold).
    func testBreathPauseDoesNotFade() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .counting, "precondition")

        coordinator.isVoiceInactive = true
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .counting,
            "widget must stay .counting during 2s hold — breath pause must not trigger fade")

        coordinator.isVoiceInactive = false
        await Task.yield()
        fakeScheduler.fire()  // cancelled timer — must be a no-op
        await Task.yield()

        XCTAssertEqual(sut.viewModel.activityState, .counting,
            "voice-resume before 2s must cancel hold: widget stays .counting")
    }

    /// Gate speechStopped + 2s with no voice-resume → widget fades to .waiting.
    /// RED fails because isVoiceInactive=true immediately sets .waiting (no hold timer to verify).
    func testSilenceOver2sFadesToWaiting() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .counting, "precondition")

        coordinator.isVoiceInactive = true
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .counting,
            "widget must stay .counting during 2s silence hold")

        fakeScheduler.fire()  // 2s hold timer fires
        await Task.yield()

        XCTAssertEqual(sut.viewModel.activityState, .waiting,
            "widget must fade to .waiting after 2s silence with no voice-resume")
    }

    /// From .waiting, gate speechStarted restores .counting immediately.
    /// RED fails because voiceInactiveSubscription ignores isVoiceInactive=false.
    func testVoiceResumeFromWaitingIsInstant() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        coordinator.isVoiceInactive = true
        await Task.yield()
        fakeScheduler.fire()  // advance hold timer to reach .waiting
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .waiting, "precondition: must reach .waiting")

        coordinator.isVoiceInactive = false
        await Task.yield()

        XCTAssertEqual(sut.viewModel.activityState, .counting,
            "gate speechStarted must instantly restore .counting from .waiting")
    }

    /// Hold timer cancelled on teardown — no .waiting transition fires after stop().
    /// RED fails because isVoiceInactive=true immediately sets .waiting (no hold timer to cancel).
    func testHoldTimerCancelledOnTeardown() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .counting, "precondition")

        coordinator.isVoiceInactive = true
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .counting,
            "hold timer pending — widget stays in .counting before teardown")

        sut.stop()
        fakeScheduler.fire()  // cancelled timer — must be a no-op

        XCTAssertNotEqual(sut.viewModel.activityState, .waiting,
            "cancelled hold timer must not set .waiting after teardown")
    }

    // MARK: - M5.1: WPM wiring via 1s widget timer (TDD-lock deviation from M4.1.B)
    // TDD-lock deviation (logged): test rewritten for M5.1. Old test drove WPMCalculator in isolation
    // and asserted via the direct Combine wpmVoicedSubscription/wpmRawSubscription. Those subscriptions
    // are removed in M5.1 and replaced by a 1s re-arming timer. New test drives FPC session lifecycle,
    // then fires the 1s widget refresh timer to prove the new data path works end-to-end.

    func testWPMVoicedFlowsToViewModel() async {
        let suite = "WPMWidgetFlow.\(name)"
        let wpmDefaults = UserDefaults(suiteName: suite)!
        wpmDefaults.removePersistentDomain(forName: suite)
        let wpmSettings = SettingsStore(userDefaults: wpmDefaults)
        let wpmScheduler = WPMTestScheduler()
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        let calc = WPMCalculator(settings: wpmSettings, scheduler: wpmScheduler, now: { clock })

        let micProvider = FakeCoreAudioDeviceProvider()
        micProvider.stubbedDefaultDeviceID = 42
        micProvider.stubbedIsRunning = false
        let micMonitor = MicMonitor(provider: micProvider)
        let coord = SessionCoordinator(micMonitor: micMonitor, settingsStore: wpmSettings)
        let fpcScheduler = FakeHideScheduler()
        let fpc = FloatingPanelController(
            sessionCoordinator: coord,
            alertPresenter: FakeAlertPresenter(),
            hideScheduler: fpcScheduler,
            settingsStore: wpmSettings,
            wpmCalculator: calc,
            reducedMotionProvider: { true }
        )

        // Start FPC session lifecycle: mic-on → engine-ready → .counting (immediate snapshot, WPM nil)
        fpc.start()
        coord.start()
        micProvider.stubbedIsRunning = true
        micProvider.simulateIsRunningChange()
        await Task.yield()
        coord.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(fpc.viewModel.activityState, .counting, "precondition")

        // Drive WPMCalculator to produce wpmVoiced after FPC entered .counting
        calc.sessionActivated()
        calc.notifyVADEvent(.speechStarted(sessionTime: 0.0))
        clock = Date(timeIntervalSinceReferenceDate: 0.6)
        calc.engineReadyFired(at: Date(timeIntervalSinceReferenceDate: 0.5))
        clock = Date(timeIntervalSinceReferenceDate: 1.1)
        await calc.consume(TranscribedToken(token: "one two three", startTime: 0, endTime: 1, isFinal: true))
        clock = Date(timeIntervalSinceReferenceDate: 3.1)
        wpmScheduler.fireNext()   // → calc.wpmVoiced = non-nil
        await Task.yield()

        // Fire the 1s widget refresh timer → snapshotNow() → viewModel updated from wpmCalculator
        fpcScheduler.fire()
        await Task.yield()

        XCTAssertNotNil(fpc.viewModel.currentWPMVoiced,
            "viewModel.currentWPMVoiced must be non-nil after 1s widget timer fires (M5.1)")
    }

    // MARK: - M5.1: Monologue level + streakSeconds wiring via 1s widget timer (TDD-lock deviation from M4.2b)
    // TDD-lock deviation (logged): test rewritten for M5.1. Old test drove MonologueDetector in
    // isolation and asserted via the direct Combine monologueLevelSubscription. That subscription is
    // removed in M5.1 and replaced by a 1s re-arming timer. New test drives FPC session lifecycle,
    // fires the 1s widget refresh timer, and asserts both monologueLevel and streakSeconds.
    // monologueLevel1Minutes = 0.5 min (30s) and clock = 31s preserved from M4.4 deviation.

    func testMonologueLevelFlowsToViewModel() async {
        let suite = "MonoWidgetFlow.\(name)"
        let monoDefaults = UserDefaults(suiteName: suite)!
        monoDefaults.removePersistentDomain(forName: suite)
        let monoSettings = SettingsStore(userDefaults: monoDefaults)
        monoSettings.monologueLevel1Minutes = 0.5  // 30s — lowest round value above 0.25-min floor

        let monoScheduler = WPMTestScheduler()
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        let detector = MonologueDetector(settings: monoSettings, scheduler: monoScheduler, now: { clock })

        let micProvider = FakeCoreAudioDeviceProvider()
        micProvider.stubbedDefaultDeviceID = 42
        micProvider.stubbedIsRunning = false
        let micMonitor = MicMonitor(provider: micProvider)
        let coord = SessionCoordinator(micMonitor: micMonitor, settingsStore: monoSettings)
        let fpcScheduler = FakeHideScheduler()
        let fpc = FloatingPanelController(
            sessionCoordinator: coord,
            alertPresenter: FakeAlertPresenter(),
            hideScheduler: fpcScheduler,
            settingsStore: monoSettings,
            monologueDetector: detector,
            reducedMotionProvider: { true }
        )

        // Start FPC session lifecycle: mic-on → engine-ready → .counting
        fpc.start()
        coord.start()
        micProvider.stubbedIsRunning = true
        micProvider.simulateIsRunningChange()
        await Task.yield()
        coord.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(fpc.viewModel.activityState, .counting, "precondition")

        // Drive MonologueDetector past L1 (0.5 min = 30s)
        detector.sessionActivated()
        detector.notifyVADEvent(.speechStarted(sessionTime: 0))
        clock = Date(timeIntervalSinceReferenceDate: 31.0)
        monoScheduler.fireNext()   // → detector.monologueLevel = 1, streakSeconds ≈ 31
        await Task.yield()

        // Fire the 1s widget refresh timer → snapshotNow() → viewModel updated
        fpcScheduler.fire()
        await Task.yield()

        XCTAssertEqual(fpc.viewModel.monologueLevel, 1,
            "monologueLevel must flow from MonologueDetector to viewModel via 1s widget timer (M5.1)")
        XCTAssertGreaterThan(fpc.viewModel.streakSeconds, 30.0,
            "streakSeconds must flow from MonologueDetector to viewModel via 1s widget timer (M5.1)")
    }

    // MARK: - M4.4: Settings-propagation tests (red phase)

    func testSilenceHoldDelayReadsWpmPauseThreshold() async {
        makeSUT()
        settingsStore.wpmPauseThreshold = 3.0
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .counting, "precondition")

        coordinator.isVoiceInactive = true
        await Task.yield()

        guard let delay = fakeScheduler.scheduledDelay else {
            XCTFail("No delay scheduled for silence hold timer")
            return
        }
        XCTAssertEqual(delay, 3.0, accuracy: 0.001,
            "silence hold timer delay must read from settingsStore.wpmPauseThreshold (M4.4 / M4.3)")
    }

    func testLingerFullDelayReadsFromSettings() async {
        makeSUT()
        settingsStore.lingerFullSeconds = 5.0
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .counting, "precondition")

        await deactivateMic()

        XCTAssertEqual(sut.panelState, .lingerFull, "precondition: session-end while counting starts lingerFull")
        guard let delay = fakeScheduler.scheduledDelay else {
            XCTFail("No delay scheduled for lingerFull timer")
            return
        }
        XCTAssertEqual(delay, 5.0, accuracy: 0.001,
            "lingerFull timer delay must read from settingsStore.lingerFullSeconds (M4.4)")
    }

    func testLingerFadeDelayReadsFromSettings() async {
        defaults = UserDefaults(suiteName: "FloatingPanelTests.\(name)")!
        defaults.removePersistentDomain(forName: "FloatingPanelTests.\(name)")
        settingsStore = SettingsStore(userDefaults: defaults)
        settingsStore.lingerFadeSeconds = 4.0
        fake = FakeCoreAudioDeviceProvider()
        fake.stubbedDefaultDeviceID = 42
        fake.stubbedIsRunning = false
        fakeAlert = FakeAlertPresenter()
        fakeScheduler = FakeHideScheduler()
        var capturedAnimationDuration: TimeInterval?
        let micMonitor = MicMonitor(provider: fake)
        coordinator = SessionCoordinator(micMonitor: micMonitor, settingsStore: settingsStore)
        sut = FloatingPanelController(
            sessionCoordinator: coordinator,
            alertPresenter: fakeAlert,
            hideScheduler: fakeScheduler,
            settingsStore: settingsStore,
            reducedMotionProvider: { false },
            runAnimation: { duration, block in
                capturedAnimationDuration = duration
                block()
            }
        )

        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        await deactivateMic()
        XCTAssertEqual(sut.panelState, .lingerFull, "precondition")

        fakeScheduler.fire()  // fires lingerFull timer → runs fade path (reducedMotion=false)

        XCTAssertEqual(sut.panelState, .lingerFade, "precondition: fade path must run")
        guard let delay = fakeScheduler.scheduledDelay else {
            XCTFail("No delay scheduled for lingerFade hide timer")
            return
        }
        XCTAssertEqual(delay, 4.0, accuracy: 0.001,
            "lingerFade hide-timer delay must read from settingsStore.lingerFadeSeconds (M4.4)")
        XCTAssertEqual(capturedAnimationDuration ?? -1, 4.0, accuracy: 0.001,
            "lingerFade animation duration must read from settingsStore.lingerFadeSeconds (M4.4)")
    }

    func testRecoveryGraceDelayReadsFromSettings() async {
        makeSUT()
        settingsStore.recoveryGraceSeconds = 4.0
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        coordinator.audioPipelineDidBeginRecovery()
        await Task.yield()
        coordinator.audioPipelineDidEndRecovery()
        await Task.yield()

        guard let delay = fakeScheduler.scheduledDelay else {
            XCTFail("No delay scheduled for recovery grace timer")
            return
        }
        XCTAssertEqual(delay, 4.0, accuracy: 0.001,
            "recovery grace timer delay must read from settingsStore.recoveryGraceSeconds (M4.4)")
    }

    // MARK: - M5.1: Widget refresh timer lifecycle

    func testWidgetTimerStartsOnEngineReady() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()

        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .counting, "precondition")

        guard let delay = fakeScheduler.scheduledDelay else {
            XCTFail("No delay scheduled after engine-ready — widget refresh timer not started (M5.1)")
            return
        }
        XCTAssertEqual(delay, 1.0, accuracy: 0.001,
            "widget refresh timer must be scheduled at 1.0s on engine-ready (M5.1)")
    }

    func testWidgetTimerStopsOnSessionIdle() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .counting, "precondition: timer must be running")
        let cancelsBefore = fakeScheduler.cancelCallCount

        await deactivateMic()

        XCTAssertGreaterThan(fakeScheduler.cancelCallCount, cancelsBefore,
            "widget refresh timer must be cancelled when session ends (M5.1)")
    }

    func testWidgetTimerStopsOnStop() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .counting, "precondition: timer must be running")
        let cancelsBefore = fakeScheduler.cancelCallCount

        sut.stop()

        XCTAssertGreaterThan(fakeScheduler.cancelCallCount, cancelsBefore,
            "widget refresh timer must be cancelled on stop() (M5.1)")
    }

    func testStreakSecondsFlowsToViewModel() async {
        let suite = "StreakFlow.\(name)"
        let streakDefaults = UserDefaults(suiteName: suite)!
        streakDefaults.removePersistentDomain(forName: suite)
        let streakSettings = SettingsStore(userDefaults: streakDefaults)

        let monoScheduler = WPMTestScheduler()
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        let detector = MonologueDetector(settings: streakSettings, scheduler: monoScheduler, now: { clock })

        let micProvider = FakeCoreAudioDeviceProvider()
        micProvider.stubbedDefaultDeviceID = 42
        micProvider.stubbedIsRunning = false
        let micMonitor = MicMonitor(provider: micProvider)
        let coord = SessionCoordinator(micMonitor: micMonitor, settingsStore: streakSettings)
        let fpcScheduler = FakeHideScheduler()
        let fpc = FloatingPanelController(
            sessionCoordinator: coord,
            alertPresenter: FakeAlertPresenter(),
            hideScheduler: fpcScheduler,
            settingsStore: streakSettings,
            monologueDetector: detector,
            reducedMotionProvider: { true }
        )

        fpc.start()
        coord.start()
        micProvider.stubbedIsRunning = true
        micProvider.simulateIsRunningChange()
        await Task.yield()
        coord.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(fpc.viewModel.activityState, .counting, "precondition")

        // Drive detector to 45s streak (below default L1=60s → monologueLevel stays 0)
        detector.sessionActivated()
        detector.notifyVADEvent(.speechStarted(sessionTime: 0))
        clock = Date(timeIntervalSinceReferenceDate: 45.0)
        monoScheduler.fireNext()   // → detector.streakSeconds ≈ 45
        await Task.yield()

        fpcScheduler.fire()
        await Task.yield()

        XCTAssertGreaterThan(fpc.viewModel.streakSeconds, 40.0,
            "streakSeconds must flow from MonologueDetector to viewModel via 1s widget timer (M5.1)")
    }

    func testResetViewModelZerosStreakSeconds() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        sut.viewModel.streakSeconds = 30.0
        XCTAssertEqual(sut.viewModel.streakSeconds, 30.0, "precondition")

        // Session ends → lingerFull starts, then fires → completeLingerHide → resetViewModel
        await deactivateMic()   // → lingerFull scheduled (overwrites widget timer cancel)
        fakeScheduler.fire()    // → completeLingerHide → resetViewModel → streakSeconds = 0

        XCTAssertEqual(sut.viewModel.streakSeconds, 0,
            "resetViewModel must zero streakSeconds (M5.1)")
    }

    // MARK: - M5.1: Immediate snapshot on .counting transition

    func testCountingTransitionForcesImmediateSnapshot() async {
        let suite = "ImmediateSnap.\(name)"
        let snapDefaults = UserDefaults(suiteName: suite)!
        snapDefaults.removePersistentDomain(forName: suite)
        let snapSettings = SettingsStore(userDefaults: snapDefaults)
        snapSettings.monologueLevel1Minutes = 0.5  // 30s

        let wpmScheduler = WPMTestScheduler()
        let monoScheduler = WPMTestScheduler()
        // Separate clocks: advancing calcClock for WPM machinery must not shift monoClock's
        // speechStartTime reference, which would produce a lower-than-expected elapsed.
        var calcClock = Date(timeIntervalSinceReferenceDate: 0)
        var monoClock = Date(timeIntervalSinceReferenceDate: 0)
        let calc = WPMCalculator(settings: snapSettings, scheduler: wpmScheduler, now: { calcClock })
        let detector = MonologueDetector(settings: snapSettings, scheduler: monoScheduler, now: { monoClock })

        let micProvider = FakeCoreAudioDeviceProvider()
        micProvider.stubbedDefaultDeviceID = 42
        micProvider.stubbedIsRunning = false
        let micMonitor = MicMonitor(provider: micProvider)
        let coord = SessionCoordinator(micMonitor: micMonitor, settingsStore: snapSettings)
        let fpc = FloatingPanelController(
            sessionCoordinator: coord,
            alertPresenter: FakeAlertPresenter(),
            hideScheduler: FakeHideScheduler(),
            settingsStore: snapSettings,
            wpmCalculator: calc,
            monologueDetector: detector,
            reducedMotionProvider: { true }
        )

        // Drive WPM to non-nil BEFORE engine-ready fires
        calc.sessionActivated()
        calc.notifyVADEvent(.speechStarted(sessionTime: 0.0))
        calcClock = Date(timeIntervalSinceReferenceDate: 0.6)
        calc.engineReadyFired(at: Date(timeIntervalSinceReferenceDate: 0.5))
        calcClock = Date(timeIntervalSinceReferenceDate: 1.1)
        await calc.consume(TranscribedToken(token: "one two three", startTime: 0, endTime: 1, isFinal: true))
        calcClock = Date(timeIntervalSinceReferenceDate: 3.1)
        wpmScheduler.fireNext()   // → calc.wpmVoiced = non-nil
        await Task.yield()

        // Drive MonologueDetector to 31s streak BEFORE engine-ready fires (monoClock independent)
        detector.sessionActivated()
        detector.notifyVADEvent(.speechStarted(sessionTime: 0))  // speechStart = monoClock = 0
        monoClock = Date(timeIntervalSinceReferenceDate: 31.0)
        monoScheduler.fireNext()   // → detector.streakSeconds = 31.0
        await Task.yield()

        // Trigger engine-ready → setActivityState(.counting) → snapshotNow() synchronously
        fpc.start()
        coord.start()
        micProvider.stubbedIsRunning = true
        micProvider.simulateIsRunningChange()
        await Task.yield()
        coord.lastEngineReadyAt = Date()   // → snapshotNow fires here
        await Task.yield()

        // Values must be present WITHOUT firing the 1s widget timer
        XCTAssertNotNil(fpc.viewModel.currentWPMVoiced,
            "immediate snapshot on .counting entry must capture WPM synchronously — no timer fire needed (M5.1)")
        XCTAssertGreaterThan(fpc.viewModel.streakSeconds, 30.0,
            "immediate snapshot on .counting entry must capture streakSeconds synchronously (M5.1)")
    }

    // MARK: - M5.1 Bug 1: first WPM value subscription
    // RED: without a wpmCalculator.$wpmVoiced subscription, the nil→non-nil transition doesn't
    // fire snapshotNow. viewModel.currentWPMVoiced stays nil until the 1s timer fires.

    func testWPMFirstValueArrivalForcesImmediateSnapshot() async {
        let suite = "WPMFirstValue.\(name)"
        let wpmDefaults = UserDefaults(suiteName: suite)!
        wpmDefaults.removePersistentDomain(forName: suite)
        let wpmSettings = SettingsStore(userDefaults: wpmDefaults)
        let wpmScheduler = WPMTestScheduler()
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        let calc = WPMCalculator(settings: wpmSettings, scheduler: wpmScheduler, now: { clock })

        let micProvider = FakeCoreAudioDeviceProvider()
        micProvider.stubbedDefaultDeviceID = 42
        micProvider.stubbedIsRunning = false
        let micMonitor = MicMonitor(provider: micProvider)
        let coord = SessionCoordinator(micMonitor: micMonitor, settingsStore: wpmSettings)
        let fpcScheduler = FakeHideScheduler()
        let fpc = FloatingPanelController(
            sessionCoordinator: coord,
            alertPresenter: FakeAlertPresenter(),
            hideScheduler: fpcScheduler,
            settingsStore: wpmSettings,
            wpmCalculator: calc,
            reducedMotionProvider: { true }
        )

        fpc.start()
        coord.start()
        micProvider.stubbedIsRunning = true
        micProvider.simulateIsRunningChange()
        await Task.yield()
        coord.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(fpc.viewModel.activityState, .counting, "precondition")
        XCTAssertNil(fpc.viewModel.currentWPMVoiced,
            "precondition: WPM must be nil at .counting entry — first hop not yet computed")

        calc.sessionActivated()
        calc.notifyVADEvent(.speechStarted(sessionTime: 0.0))
        clock = Date(timeIntervalSinceReferenceDate: 0.6)
        calc.engineReadyFired(at: Date(timeIntervalSinceReferenceDate: 0.5))
        clock = Date(timeIntervalSinceReferenceDate: 1.1)
        await calc.consume(TranscribedToken(token: "one two three", startTime: 0, endTime: 1, isFinal: true))
        clock = Date(timeIntervalSinceReferenceDate: 3.1)
        wpmScheduler.fireNext()  // → calc.wpmVoiced becomes non-nil → subscription → snapshotNow()
        await Task.yield()

        // No fpcScheduler.fire() — the subscription must push the value without timer fire
        XCTAssertNotNil(fpc.viewModel.currentWPMVoiced,
            "first WPM value arriving must immediately snapshot to viewModel without 1s timer fire (M5.1 Bug 1)")
    }

    func testWPMFirstValueArrivalRePhasesTimer() async {
        let suite = "WPMRePhase.\(name)"
        let wpmDefaults = UserDefaults(suiteName: suite)!
        wpmDefaults.removePersistentDomain(forName: suite)
        let wpmSettings = SettingsStore(userDefaults: wpmDefaults)
        let wpmScheduler = WPMTestScheduler()
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        let calc = WPMCalculator(settings: wpmSettings, scheduler: wpmScheduler, now: { clock })

        let micProvider = FakeCoreAudioDeviceProvider()
        micProvider.stubbedDefaultDeviceID = 42
        micProvider.stubbedIsRunning = false
        let micMonitor = MicMonitor(provider: micProvider)
        let coord = SessionCoordinator(micMonitor: micMonitor, settingsStore: wpmSettings)
        let fpcScheduler = FakeHideScheduler()
        let fpc = FloatingPanelController(
            sessionCoordinator: coord,
            alertPresenter: FakeAlertPresenter(),
            hideScheduler: fpcScheduler,
            settingsStore: wpmSettings,
            wpmCalculator: calc,
            reducedMotionProvider: { true }
        )

        fpc.start()
        coord.start()
        micProvider.stubbedIsRunning = true
        micProvider.simulateIsRunningChange()
        await Task.yield()
        coord.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(fpc.viewModel.activityState, .counting, "precondition")
        let cancelCountAfterCounting = fpcScheduler.cancelCallCount

        calc.sessionActivated()
        calc.notifyVADEvent(.speechStarted(sessionTime: 0.0))
        clock = Date(timeIntervalSinceReferenceDate: 0.6)
        calc.engineReadyFired(at: Date(timeIntervalSinceReferenceDate: 0.5))
        clock = Date(timeIntervalSinceReferenceDate: 1.1)
        await calc.consume(TranscribedToken(token: "one two three", startTime: 0, endTime: 1, isFinal: true))
        clock = Date(timeIntervalSinceReferenceDate: 3.1)
        wpmScheduler.fireNext()  // → calc.wpmVoiced non-nil → subscription fires → re-phases timer
        await Task.yield()

        XCTAssertGreaterThan(fpcScheduler.cancelCallCount, cancelCountAfterCounting,
            "first WPM value must cancel existing timer token to re-phase from current moment (M5.1 Bug 1)")
        guard let rePhasedDelay = fpcScheduler.scheduledDelay else {
            XCTFail("no timer rescheduled after first WPM value — re-phasing did not fire (M5.1 Bug 1)")
            return
        }
        XCTAssertEqual(rePhasedDelay, 1.0, accuracy: 0.001,
            "fresh 1s timer must be re-armed after first WPM value arrives (M5.1 Bug 1)")
    }

    // MARK: - M5.1 Bug 2: exit snapshot on .counting → non-.counting
    // RED: without snapshotNow() in the exit branch, stale WPM and streakSeconds values set during
    // .counting persist into .waiting because the timer stops before it can write the nil/0 snapshot.

    func testCountingToWaitingForcesFinalSnapshot() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .counting, "precondition")

        // Simulate stale values that would persist without an exit snapshot
        sut.viewModel.currentWPMVoiced = 120
        sut.viewModel.streakSeconds = 45.0

        coordinator.isVoiceInactive = true
        await Task.yield()
        fakeScheduler.fire()  // silence hold fires → enterWaiting() on nil calculators → .waiting
        await Task.yield()

        XCTAssertEqual(sut.viewModel.activityState, .waiting, "precondition")
        XCTAssertNil(sut.viewModel.currentWPMVoiced,
            "exit from .counting must snapshot nil — stale WPM must not persist into .waiting (M5.1 Bug 2)")
        XCTAssertEqual(sut.viewModel.streakSeconds, 0.0, accuracy: 0.001,
            "exit from .counting must snapshot 0 — stale streakSeconds must not persist into .waiting (M5.1 Bug 2)")
    }

    func testCountingToWaitingStopsTimerAfterSnapshot() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .counting, "precondition")

        sut.viewModel.currentWPMVoiced = 99
        let cancelsBefore = fakeScheduler.cancelCallCount

        coordinator.isVoiceInactive = true
        await Task.yield()
        fakeScheduler.fire()  // silence hold → snapshotNow() + stopWidgetRefreshTimer()
        await Task.yield()

        XCTAssertGreaterThan(fakeScheduler.cancelCallCount, cancelsBefore,
            "widget refresh timer must be cancelled when .counting exits to .waiting (M5.1 Bug 2)")
        XCTAssertNil(sut.viewModel.currentWPMVoiced,
            "stale WPM must be cleared synchronously by exit snapshot before timer stops (M5.1 Bug 2)")
    }

    // MARK: - Resume-snapshot fixture (extracted to keep testWaitingToCountingResumeForcesImmediateSnapshot under 50 lines)

    private struct ResumeFPCComponents {
        let resumeSettings: SettingsStore
        let wpmScheduler: WPMTestScheduler
        let monoScheduler: WPMTestScheduler
        let calc: WPMCalculator
        let detector: MonologueDetector
        let micProvider: FakeCoreAudioDeviceProvider
        let coord: SessionCoordinator
        let fpcScheduler: FakeHideScheduler
        let fpc: FloatingPanelController
    }

    private func makeResumeFPCComponents(clock: @escaping () -> Date) -> ResumeFPCComponents {
        let suite = "ResumeSnap.\(name)"
        let resumeDefaults = UserDefaults(suiteName: suite)!
        resumeDefaults.removePersistentDomain(forName: suite)
        let resumeSettings = SettingsStore(userDefaults: resumeDefaults)
        let wpmScheduler = WPMTestScheduler()
        let monoScheduler = WPMTestScheduler()
        let calc = WPMCalculator(settings: resumeSettings, scheduler: wpmScheduler, now: clock)
        let detector = MonologueDetector(settings: resumeSettings, scheduler: monoScheduler, now: clock)
        let micProvider = FakeCoreAudioDeviceProvider()
        micProvider.stubbedDefaultDeviceID = 42
        micProvider.stubbedIsRunning = false
        let micMonitor = MicMonitor(provider: micProvider)
        let coord = SessionCoordinator(micMonitor: micMonitor, settingsStore: resumeSettings)
        let fpcScheduler = FakeHideScheduler()
        let fpc = FloatingPanelController(
            sessionCoordinator: coord,
            alertPresenter: FakeAlertPresenter(),
            hideScheduler: fpcScheduler,
            settingsStore: resumeSettings,
            wpmCalculator: calc,
            monologueDetector: detector,
            reducedMotionProvider: { true }
        )
        return ResumeFPCComponents(
            resumeSettings: resumeSettings, wpmScheduler: wpmScheduler, monoScheduler: monoScheduler,
            calc: calc, detector: detector, micProvider: micProvider,
            coord: coord, fpcScheduler: fpcScheduler, fpc: fpc
        )
    }

    func testWaitingToCountingResumeForcesImmediateSnapshot() async {
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        let fix = makeResumeFPCComponents(clock: { clock })

        // Reach .waiting via full session lifecycle
        fix.fpc.start()
        fix.coord.start()
        fix.micProvider.stubbedIsRunning = true
        fix.micProvider.simulateIsRunningChange()
        await Task.yield()
        fix.coord.lastEngineReadyAt = Date()   // → .counting
        await Task.yield()
        XCTAssertEqual(fix.fpc.viewModel.activityState, .counting, "precondition")

        // Silence hold → .waiting
        fix.coord.isVoiceInactive = true
        await Task.yield()
        fix.fpcScheduler.fire()   // → silence hold fires → enterWaiting() → .waiting
        await Task.yield()
        XCTAssertEqual(fix.fpc.viewModel.activityState, .waiting, "precondition: must reach .waiting")

        // Drive WPM and streak to known values while in .waiting
        fix.calc.sessionActivated()
        fix.calc.notifyVADEvent(.speechStarted(sessionTime: 0.0))
        clock = Date(timeIntervalSinceReferenceDate: 0.6)
        fix.calc.engineReadyFired(at: Date(timeIntervalSinceReferenceDate: 0.5))
        clock = Date(timeIntervalSinceReferenceDate: 1.1)
        await fix.calc.consume(TranscribedToken(token: "one two three", startTime: 0, endTime: 1, isFinal: true))
        clock = Date(timeIntervalSinceReferenceDate: 3.1)
        fix.wpmScheduler.fireNext()
        await Task.yield()
        fix.detector.sessionActivated()
        fix.detector.notifyVADEvent(.speechStarted(sessionTime: 0))
        clock = Date(timeIntervalSinceReferenceDate: 45.0)
        fix.monoScheduler.fireNext()   // → detector.streakSeconds ≈ 45
        await Task.yield()

        // Voice resumes → .counting → snapshotNow() synchronously
        fix.coord.isVoiceInactive = false
        await Task.yield()

        XCTAssertEqual(fix.fpc.viewModel.activityState, .counting,
            "precondition: voice resume must restore .counting")
        XCTAssertNotNil(fix.fpc.viewModel.currentWPMVoiced,
            "immediate snapshot on .waiting→.counting must capture WPM synchronously (M5.1)")
        XCTAssertGreaterThan(fix.fpc.viewModel.streakSeconds, 40.0,
            "immediate snapshot on .waiting→.counting must capture streakSeconds synchronously (M5.1)")
    }

    // MARK: - M5.4a: hasReceivedWPM persists through a waiting cycle (no mark on resume)

    func testHasReceivedWPM_survivesWaitingReEntry() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .counting, "precondition")

        // Simulate first WPM arriving — triggers hasReceivedWPM=true via WidgetViewModel's Combine sink.
        sut.viewModel.currentWPMVoiced = 130
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(sut.viewModel.hasReceivedWPM, "precondition: hasReceivedWPM set by first WPM")

        // Silence hold fires → .waiting; snapshotNow reads nil from nil calculator → currentWPMVoiced=nil.
        coordinator.isVoiceInactive = true
        await Task.yield()
        fakeScheduler.fire()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .waiting, "precondition: .waiting after silence hold")

        // Voice resumes → .counting with nil WPM (skipOpacityChange active, no calculator).
        coordinator.isVoiceInactive = false
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .counting, "precondition: .counting after vad-active")

        XCTAssertTrue(sut.viewModel.hasReceivedWPM,
            "hasReceivedWPM must remain true through a mid-session waiting cycle — resetViewModel is never called here (M5.4a)")
        XCTAssertFalse(
            WidgetView.showColdStartMark(activityState: sut.viewModel.activityState, hasReceivedWPM: sut.viewModel.hasReceivedWPM),
            "cold-start mark must not reappear on resume from waiting: dashes hold, not the pulsing mark (M5.4a)"
        )
    }

    // MARK: - M5.4a: waiting→counting with nil WPM defers opacity raise (no bright-dashes flash)

    func testWaitingToCountingNilWPM_skipsOpacityRaise() async {
        let suiteName = "WaitingSkipOpacity.\(name)"
        let defs = UserDefaults(suiteName: suiteName)!
        defs.removePersistentDomain(forName: suiteName)
        defs.set(true, forKey: "coachingEnabled")
        let skipSettings = SettingsStore(userDefaults: defs)
        let skipDev = FakeCoreAudioDeviceProvider()
        skipDev.stubbedDefaultDeviceID = 42
        skipDev.stubbedIsRunning = false
        let skipAlert = FakeAlertPresenter()
        let skipSched = FakeHideScheduler()
        let skipMic = MicMonitor(provider: skipDev)
        let skipCoord = SessionCoordinator(micMonitor: skipMic, settingsStore: skipSettings)
        var animationCalls: [TimeInterval] = []
        let skipFPC = FloatingPanelController(
            sessionCoordinator: skipCoord,
            alertPresenter: skipAlert,
            hideScheduler: skipSched,
            settingsStore: skipSettings,
            reducedMotionProvider: { true },
            runAnimation: { dur, block in animationCalls.append(dur); block() }
        )

        skipFPC.start()
        skipCoord.start()
        skipDev.stubbedIsRunning = true
        skipDev.simulateIsRunningChange()
        await Task.yield()
        skipCoord.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(skipFPC.viewModel.activityState, .counting, "precondition")

        // Silence hold → .waiting
        skipCoord.isVoiceInactive = true
        await Task.yield()
        skipSched.fire()
        await Task.yield()
        XCTAssertEqual(skipFPC.viewModel.activityState, .waiting, "precondition")

        // Clear any opacity calls accumulated during warming/counting/waiting transitions.
        animationCalls.removeAll()

        // Resume → .counting with nil WPM (no calculator injected). skipOpacityChange must suppress
        // the opacity raise that would otherwise flash the dashes to full brightness before a number lands.
        skipCoord.isVoiceInactive = false
        await Task.yield()
        XCTAssertEqual(skipFPC.viewModel.activityState, .counting, "precondition: resumed to .counting")
        XCTAssertNil(skipFPC.viewModel.currentWPMVoiced, "precondition: WPM nil (no calculator)")

        XCTAssertTrue(animationCalls.isEmpty,
            "runAnimation must NOT be called on waiting→counting with nil WPM — skipOpacityChange guard defers opacity raise until first WPM arrives (S045 smoke #5, M5.4a)")
    }

    // MARK: - M5.4a: first WPM after waiting triggers 0.7s animated opacity raise (S045 smoke #5)

    // swiftlint:disable:next function_body_length
    func testFirstWPMAfterWaiting_raisesAlpha_0_7s() async {
        let suiteName = "FirstWPMAfterWaiting.\(name)"
        let defs = UserDefaults(suiteName: suiteName)!
        defs.removePersistentDomain(forName: suiteName)
        let raisedSettings = SettingsStore(userDefaults: defs)

        let wpmSched = WPMTestScheduler()
        var clock = Date(timeIntervalSinceReferenceDate: 0.0)
        let calc = WPMCalculator(settings: raisedSettings, scheduler: wpmSched, now: { clock })

        let raisedDev = FakeCoreAudioDeviceProvider()
        raisedDev.stubbedDefaultDeviceID = 42
        raisedDev.stubbedIsRunning = false
        let raisedAlert = FakeAlertPresenter()
        let raisedSched = FakeHideScheduler()
        let raisedMic = MicMonitor(provider: raisedDev)
        let raisedCoord = SessionCoordinator(micMonitor: raisedMic, settingsStore: raisedSettings)
        var animationCalls: [TimeInterval] = []
        let raisedFPC = FloatingPanelController(
            sessionCoordinator: raisedCoord,
            alertPresenter: raisedAlert,
            hideScheduler: raisedSched,
            settingsStore: raisedSettings,
            wpmCalculator: calc,
            reducedMotionProvider: { true },
            runAnimation: { dur, block in animationCalls.append(dur); block() }
        )

        // Drive to .counting
        raisedFPC.start()
        raisedCoord.start()
        raisedDev.stubbedIsRunning = true
        raisedDev.simulateIsRunningChange()
        await Task.yield()
        raisedCoord.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(raisedFPC.viewModel.activityState, .counting, "precondition")

        // Arm WPMCalculator (matches production wiring sequence)
        calc.sessionActivated()
        calc.engineReadyFired(at: Date(timeIntervalSinceReferenceDate: 0.0))  // engineReadyCutoff = 0.5

        // Silence hold → .waiting (enterWaiting clears calculator state, wpmFirstValueSubscription torn down)
        raisedCoord.isVoiceInactive = true
        await Task.yield()
        raisedSched.fire()
        await Task.yield()
        XCTAssertEqual(raisedFPC.viewModel.activityState, .waiting, "precondition")
        XCTAssertNil(raisedFPC.viewModel.currentWPMVoiced, "precondition: WPM cleared by enterWaiting")

        // Resume → .counting (nil WPM, skipOpacityChange; wpmFirstValueSubscription re-established)
        raisedCoord.isVoiceInactive = false
        await Task.yield()
        XCTAssertEqual(raisedFPC.viewModel.activityState, .counting, "precondition: resumed to .counting")

        // Clear opacity calls from setup (warming/counting/waiting/resume transitions)
        animationCalls.removeAll()

        // Drive WPMCalculator via the production re-arm path (speechStarted restarts the refresh loop
        // when refreshToken==nil and engineReadyCutoff!=nil). New speech + tokens meet the floor guards.
        calc.notifyVADEvent(.speechStarted(sessionTime: 0))   // re-arms loop; currentSpeechStart = t=0
        clock = Date(timeIntervalSinceReferenceDate: 1.0)     // arrival time for token (> cutoff 0.5)
        await calc.consume(TranscribedToken(token: "one two three four", startTime: 0, endTime: 1, isFinal: true))
        clock = Date(timeIntervalSinceReferenceDate: 3.5)
        // voicedSec: clippedStart=max(0.0, 0.5)=0.5; voiced=3.5−0.5=3.0 ≥ 2.0 ✓; words=4 ≥ 3 ✓
        wpmSched.fireNext()  // computeAndPublish → wpmVoiced = non-nil → wpmFirstValueSubscription fires

        XCTAssertNotNil(raisedFPC.viewModel.currentWPMVoiced,
            "first WPM after waiting must land in viewModel immediately via wpmFirstValueSubscription (M5.4a)")
        XCTAssertTrue(animationCalls.contains(where: { abs($0 - 0.7) < 0.01 }),
            "applyPanelOpacity(duration: 0.7) must fire on first WPM after waiting — animated fade from dim to workingOpacity, not an instant snap (S045 smoke #5, M5.4a)")
    }

    // MARK: - M5.7 Part 3: counting fires only on first WPM (wpmGateSubscription)

    // engine-ready was the primary warming→counting trigger. M5.7 removes it — no-op on activityState.
    func testEngineReady_doesNotChangeActivityState() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        XCTAssertEqual(sut.viewModel.activityState, .warming, "precondition: .warming after mic-on")

        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        XCTAssertEqual(sut.viewModel.activityState, .warming,
            "engine-ready must NOT change activityState — .counting fires only on first WPM (M5.7)")
    }

    // Token arrival while in .warming must not change activityState (M5.7).
    func testTokenArrival_inWarming_doesNotChangeActivityState() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        XCTAssertEqual(sut.viewModel.activityState, .warming, "precondition: .warming after mic-on")

        coordinator.lastTokenArrival = Date()
        await Task.yield()

        XCTAssertEqual(sut.viewModel.activityState, .warming,
            "token arrival in .warming must NOT trigger .counting — .counting requires first WPM (M5.7)")
    }

    // First non-nil WPM in .warming fires wpmGateSubscription → .counting (M5.7).
    // swiftlint:disable:next function_body_length
    func testFirstWPM_inWarming_transitionsToCounting() async {
        let suite = "FirstWPMWarming.\(name)"
        let defs = UserDefaults(suiteName: suite)!
        defs.removePersistentDomain(forName: suite)
        let settings = SettingsStore(userDefaults: defs)
        let wpmSched = WPMTestScheduler()
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        let calc = WPMCalculator(settings: settings, scheduler: wpmSched, now: { clock })
        let micProv = FakeCoreAudioDeviceProvider()
        micProv.stubbedDefaultDeviceID = 42
        micProv.stubbedIsRunning = false
        let mic = MicMonitor(provider: micProv)
        let coord = SessionCoordinator(micMonitor: mic, settingsStore: settings)
        let fpc = FloatingPanelController(
            sessionCoordinator: coord,
            alertPresenter: FakeAlertPresenter(),
            hideScheduler: FakeHideScheduler(),
            settingsStore: settings,
            wpmCalculator: calc,
            reducedMotionProvider: { true }
        )
        fpc.start()
        coord.start()
        micProv.stubbedIsRunning = true
        micProv.simulateIsRunningChange()
        await Task.yield()
        XCTAssertEqual(fpc.viewModel.activityState, .warming, "precondition: .warming after mic-on")

        calc.sessionActivated()
        calc.notifyVADEvent(.speechStarted(sessionTime: 0.0))
        clock = Date(timeIntervalSinceReferenceDate: 0.6)
        calc.engineReadyFired(at: Date(timeIntervalSinceReferenceDate: 0.5))
        clock = Date(timeIntervalSinceReferenceDate: 1.1)
        await calc.consume(TranscribedToken(token: "one two three", startTime: 0, endTime: 1, isFinal: true))
        clock = Date(timeIntervalSinceReferenceDate: 3.1)
        wpmSched.fireNext()   // calc.wpmVoiced becomes non-nil → wpmGateSubscription sink fires
        await Task.yield()

        XCTAssertEqual(fpc.viewModel.activityState, .counting,
            "first non-nil WPM in .warming must transition to .counting via wpmGateSubscription (M5.7)")
    }

    // Voice-resume from .waiting arms the gate only; state stays .waiting until first WPM (M5.7).
    func testWaiting_resumes_staysWaitingUntilFirstWPM() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()   // precondition shortcut; migrated to WPM path in green
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .counting, "precondition: reach .counting")

        coordinator.isVoiceInactive = true
        await Task.yield()
        fakeScheduler.fire()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .waiting, "precondition: reach .waiting via silence hold")

        coordinator.isVoiceInactive = false
        await Task.yield()

        XCTAssertEqual(sut.viewModel.activityState, .waiting,
            "voice-resume from .waiting must NOT immediately enter .counting — gate waits for first WPM (M5.7)")
    }

    // First non-nil WPM after voice-resume from .waiting fires gate → .counting (M5.7).
    // swiftlint:disable:next function_body_length
    func testFirstWPM_inWaiting_transitionsToCounting() async {
        let suite = "FirstWPMWaiting.\(name)"
        let defs = UserDefaults(suiteName: suite)!
        defs.removePersistentDomain(forName: suite)
        let settings = SettingsStore(userDefaults: defs)
        let wpmSched = WPMTestScheduler()
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        let calc = WPMCalculator(settings: settings, scheduler: wpmSched, now: { clock })
        let micProv = FakeCoreAudioDeviceProvider()
        micProv.stubbedDefaultDeviceID = 42
        micProv.stubbedIsRunning = false
        let mic = MicMonitor(provider: micProv)
        let coord = SessionCoordinator(micMonitor: mic, settingsStore: settings)
        let fpcSched = FakeHideScheduler()
        let fpc = FloatingPanelController(
            sessionCoordinator: coord,
            alertPresenter: FakeAlertPresenter(),
            hideScheduler: fpcSched,
            settingsStore: settings,
            wpmCalculator: calc,
            reducedMotionProvider: { true }
        )
        fpc.start()
        coord.start()
        micProv.stubbedIsRunning = true
        micProv.simulateIsRunningChange()
        await Task.yield()
        coord.lastEngineReadyAt = Date()   // precondition shortcut; migrated to WPM path in green
        await Task.yield()
        XCTAssertEqual(fpc.viewModel.activityState, .counting, "precondition: reach .counting via engine-ready")

        calc.sessionActivated()
        calc.engineReadyFired(at: Date(timeIntervalSinceReferenceDate: 0.0))

        coord.isVoiceInactive = true
        await Task.yield()
        fpcSched.fire()
        await Task.yield()
        XCTAssertEqual(fpc.viewModel.activityState, .waiting, "precondition: reach .waiting via silence hold")

        // Voice-resume arms the gate; must stay .waiting until WPM arrives
        coord.isVoiceInactive = false
        await Task.yield()
        XCTAssertEqual(fpc.viewModel.activityState, .waiting,
            "after voice-resume, must stay .waiting until first WPM (M5.7)")

        calc.notifyVADEvent(.speechStarted(sessionTime: 0))
        clock = Date(timeIntervalSinceReferenceDate: 1.0)
        await calc.consume(TranscribedToken(
            token: "one two three four", startTime: 0, endTime: 1, isFinal: true))
        clock = Date(timeIntervalSinceReferenceDate: 3.5)
        wpmSched.fireNext()   // calc.wpmVoiced non-nil → gate fires → .counting
        await Task.yield()

        XCTAssertEqual(fpc.viewModel.activityState, .counting,
            "first WPM after voice-resume from .waiting must enter .counting via wpmGateSubscription (M5.7)")
        XCTAssertNotNil(fpc.viewModel.currentWPMVoiced,
            "WPM must flow to viewModel when gate fires from .waiting (M5.7)")
    }

    // MARK: - M5.7 Part 2: hover alpha override (FPC window-level)

    // Hover-enter must trigger runAnimation and set panel alphaValue to 1.0 (M5.7 Part 2).
    func testHoverActive_overridesAlphaTo1() async {
        let suiteName = "HoverEnter.\(name)"
        let defs = UserDefaults(suiteName: suiteName)!
        defs.removePersistentDomain(forName: suiteName)
        defs.set(true, forKey: "coachingEnabled")
        let settings = SettingsStore(userDefaults: defs)
        let dev = FakeCoreAudioDeviceProvider()
        dev.stubbedDefaultDeviceID = 42
        dev.stubbedIsRunning = false
        let coord = SessionCoordinator(micMonitor: MicMonitor(provider: dev), settingsStore: settings)
        var animationCount = 0
        let fpc = FloatingPanelController(
            sessionCoordinator: coord,
            alertPresenter: FakeAlertPresenter(),
            hideScheduler: FakeHideScheduler(),
            settingsStore: settings,
            reducedMotionProvider: { false },
            runAnimation: { _, block in animationCount += 1; block() }
        )
        fpc.start()
        coord.start()
        dev.stubbedIsRunning = true
        dev.simulateIsRunningChange()
        await Task.yield()
        XCTAssertEqual(fpc.viewModel.activityState, .warming, "precondition: panel visible in .warming")
        animationCount = 0

        fpc.handleHoverEntered()

        XCTAssertGreaterThan(animationCount, 0,
            "hover-enter must call runAnimation to raise alpha to 1.0 (M5.7 Part 2)")
        XCTAssertEqual(fpc.panelWindow?.alphaValue ?? -1, 1.0, accuracy: 0.001,
            "hover-enter must set panel alphaValue to 1.0 (M5.7 Part 2)")
    }

    // Hover-exit must trigger runAnimation to restore the state's natural alpha (M5.7 Part 2).
    func testHoverInactive_restoresNaturalAlpha() async {
        let suiteName = "HoverExit.\(name)"
        let defs = UserDefaults(suiteName: suiteName)!
        defs.removePersistentDomain(forName: suiteName)
        defs.set(true, forKey: "coachingEnabled")
        let settings = SettingsStore(userDefaults: defs)
        let dev = FakeCoreAudioDeviceProvider()
        dev.stubbedDefaultDeviceID = 42
        dev.stubbedIsRunning = false
        let coord = SessionCoordinator(micMonitor: MicMonitor(provider: dev), settingsStore: settings)
        var animationCount = 0
        let fpc = FloatingPanelController(
            sessionCoordinator: coord,
            alertPresenter: FakeAlertPresenter(),
            hideScheduler: FakeHideScheduler(),
            settingsStore: settings,
            reducedMotionProvider: { false },
            runAnimation: { _, block in animationCount += 1; block() }
        )
        fpc.start()
        coord.start()
        dev.stubbedIsRunning = true
        dev.simulateIsRunningChange()
        await Task.yield()
        fpc.handleHoverEntered()
        animationCount = 0

        fpc.handleHoverExited()

        XCTAssertGreaterThan(animationCount, 0,
            "hover-exit must call runAnimation to restore natural alpha (M5.7 Part 2)")
    }

    // Hover animation duration must be 0 when Reduce Motion is on (M5.7 Part 2).
    func testHoverAlphaDurationIsZeroWhenReduceMotionOn() async {
        let suiteName = "HoverReduceMotion.\(name)"
        let defs = UserDefaults(suiteName: suiteName)!
        defs.removePersistentDomain(forName: suiteName)
        defs.set(true, forKey: "coachingEnabled")
        let settings = SettingsStore(userDefaults: defs)
        let dev = FakeCoreAudioDeviceProvider()
        dev.stubbedDefaultDeviceID = 42
        dev.stubbedIsRunning = false
        let coord = SessionCoordinator(micMonitor: MicMonitor(provider: dev), settingsStore: settings)
        var capturedDurations: [TimeInterval] = []
        let fpc = FloatingPanelController(
            sessionCoordinator: coord,
            alertPresenter: FakeAlertPresenter(),
            hideScheduler: FakeHideScheduler(),
            settingsStore: settings,
            reducedMotionProvider: { true },
            runAnimation: { dur, block in capturedDurations.append(dur); block() }
        )
        fpc.start()
        coord.start()
        dev.stubbedIsRunning = true
        dev.simulateIsRunningChange()
        await Task.yield()
        capturedDurations.removeAll()

        fpc.handleHoverEntered()

        XCTAssertFalse(capturedDurations.isEmpty,
            "hover-enter with reduce-motion ON must still call runAnimation (duration 0) (M5.7 Part 2)")
        XCTAssertTrue(capturedDurations.allSatisfy { $0 == 0.0 },
            "hover animation duration must be 0 when reducedMotionProvider returns true (M5.7 Part 2)")
    }

    // State changes during hover must not call applyPanelOpacity — isHoverActive guard suppresses it (M5.7 Part 2).
    func testApplyPanelOpacity_notCalledWhileHoverActive() async {
        let suiteName = "HoverSkipOpacity.\(name)"
        let defs = UserDefaults(suiteName: suiteName)!
        defs.removePersistentDomain(forName: suiteName)
        defs.set(true, forKey: "coachingEnabled")
        let settings = SettingsStore(userDefaults: defs)
        let dev = FakeCoreAudioDeviceProvider()
        dev.stubbedDefaultDeviceID = 42
        dev.stubbedIsRunning = false
        let sched = FakeHideScheduler()
        let coord = SessionCoordinator(micMonitor: MicMonitor(provider: dev), settingsStore: settings)
        var animationCount = 0
        let fpc = FloatingPanelController(
            sessionCoordinator: coord,
            alertPresenter: FakeAlertPresenter(),
            hideScheduler: sched,
            settingsStore: settings,
            reducedMotionProvider: { true },
            runAnimation: { _, block in animationCount += 1; block() }
        )
        fpc.start()
        coord.start()
        dev.stubbedIsRunning = true
        dev.simulateIsRunningChange()
        await Task.yield()
        coord.lastEngineReadyAt = Date()   // precondition shortcut; migrated to WPM path in green
        await Task.yield()
        XCTAssertEqual(fpc.viewModel.activityState, .counting, "precondition: .counting")

        fpc.handleHoverEntered()
        animationCount = 0

        coord.isVoiceInactive = true
        await Task.yield()
        sched.fire()
        await Task.yield()

        XCTAssertEqual(animationCount, 0,
            "applyPanelOpacity must be suppressed while isHoverActive — hover holds alpha at 1.0 (M5.7 Part 2)")
    }
}
