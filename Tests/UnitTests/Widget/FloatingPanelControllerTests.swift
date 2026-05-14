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
            settingsStore: settingsStore
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

    // MARK: - Show on activation

    func testShowOnMicActivation() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()

        XCTAssertEqual(sut.panelState, .visible)
        XCTAssertTrue(sut.isShowingPanel)
    }

    // MARK: - Idempotent visible state

    func testStayVisibleOnReemittedActiveState() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        XCTAssertEqual(sut.panelState, .visible)

        fake.simulateIsRunningChange()
        await Task.yield()

        XCTAssertEqual(sut.panelState, .visible)
        XCTAssertTrue(sut.isShowingPanel)
    }

    // MARK: - Hide after mic-off with scheduler

    func testHideAfterMicOffWithScheduler() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        await deactivateMic()

        // M3.7.3: session-end now hides immediately via token-silence path; no fade timer scheduled
        XCTAssertEqual(sut.panelState, .hidden,
                       "M3.7.3: session end must hide immediately — fade is driven by token-silence, not session state")
        XCTAssertFalse(sut.isShowingPanel)
    }

    // MARK: - Hide cancellation on rapid reactivation

    func testHideCancellationOnRapidReactivation() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        await deactivateMic()
        // M3.7.3: session-end hides immediately — no fade timer scheduled
        XCTAssertEqual(sut.panelState, .hidden,
                       "M3.7.3: session end must hide immediately; fade is driven by token-silence")

        await activateMic()
        XCTAssertEqual(sut.panelState, .visible)

        fakeScheduler.fire()
        XCTAssertEqual(sut.panelState, .visible, "Firing empty scheduler must not hide the panel")
        XCTAssertTrue(sut.isShowingPanel)
    }

    // MARK: - Dismiss confirmation

    func testDismissConfirmYesHidesImmediately() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        fakeAlert.stubbedResult = true

        sut.requestDismiss()

        XCTAssertEqual(fakeAlert.presentCallCount, 1)
        XCTAssertEqual(sut.panelState, .dismissed)
        XCTAssertFalse(sut.isShowingPanel)
        XCTAssertNotEqual(coordinator.state, .idle, "Coordinator state must remain active")
    }

    func testDismissConfirmNoKeepsVisible() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
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
        fakeAlert.stubbedResult = true
        sut.requestDismiss()
        XCTAssertEqual(sut.panelState, .dismissed)

        await deactivateMic()
        XCTAssertEqual(sut.panelState, .hidden)

        await activateMic()
        XCTAssertEqual(sut.panelState, .visible)
        XCTAssertTrue(sut.isShowingPanel, "Panel must re-appear after dismissal scope clears")
    }

    // MARK: - Pause mid-session uses fade timer

    func testPauseMidSessionUsesFadeTimer() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        XCTAssertEqual(sut.panelState, .visible)

        settingsStore.coachingEnabled = false
        await Task.yield()

        // M3.7.3: session-end (coaching disabled) now hides immediately; no fade timer
        XCTAssertEqual(sut.panelState, .hidden,
                       "M3.7.3: coaching-disabled session end must hide immediately — fade is driven by token-silence")
    }

    // MARK: - Lifecycle idempotency

    func testStartIdempotent() async {
        makeSUT()
        sut.start()
        sut.start()
        coordinator.start()
        await activateMic()

        XCTAssertEqual(sut.panelState, .visible)

        await deactivateMic()
        fakeScheduler.fire()
        await activateMic()

        XCTAssertEqual(sut.panelState, .visible, "Only one observation path — no double show")
    }

    func testStopWhileVisibleHidesImmediately() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
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
        await deactivateMic()
        // M3.7.3: session-end hides immediately
        XCTAssertEqual(sut.panelState, .hidden,
                       "M3.7.3: session end must hide immediately")

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
        XCTAssertEqual(sut.panelState, .visible)

        await deactivateMic()
        // M3.7.3: session-end hides immediately
        XCTAssertEqual(sut.panelState, .hidden,
                       "M3.7.3: session end must hide immediately")

        await activateMic()
        XCTAssertEqual(sut.panelState, .visible)

        await deactivateMic()
        XCTAssertEqual(sut.panelState, .hidden,
                       "M3.7.3: second session end must also hide immediately")

        // fire() is a no-op: nothing was scheduled by session-end
        fakeScheduler.fire()
        XCTAssertEqual(sut.panelState, .hidden)
    }

    // MARK: - Dismiss while fading out is no-op

    func testDismissWhileHiddenIsNoOp() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        await deactivateMic()
        // M3.7.3: session-end hides immediately
        XCTAssertEqual(sut.panelState, .hidden,
                       "M3.7.3: session end must hide immediately")

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
        XCTAssertEqual(sut.panelState, .visible)
    }
}
