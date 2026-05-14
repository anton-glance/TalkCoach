// swiftlint:disable file_length
import XCTest
@testable import TalkCoach

// MARK: - Test doubles (private to this file — distinct from FloatingPanelControllerTests versions)

private final class WidgetTestAlertPresenter: AlertPresenter, @unchecked Sendable {
    @MainActor func presentDismissConfirmation() -> Bool { false }
}

private final class ConfirmingWidgetAlertPresenter: AlertPresenter, @unchecked Sendable {
    @MainActor func presentDismissConfirmation() -> Bool { true }
}

private final class WidgetTestHideScheduler: HideScheduler, @unchecked Sendable {
    nonisolated(unsafe) private(set) var scheduledActions: [(@MainActor @Sendable () -> Void)] = []
    nonisolated(unsafe) private(set) var scheduledDelays: [TimeInterval] = []
    nonisolated(unsafe) private(set) var cancelCallCount = 0

    var lastScheduledDelay: TimeInterval? { scheduledDelays.last }

    @MainActor func schedule(
        delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> HideSchedulerToken {
        scheduledDelays.append(delay)
        scheduledActions.append(action)
        return HideSchedulerToken()
    }

    @MainActor func cancel(_ token: HideSchedulerToken) {
        cancelCallCount += 1
    }

    @MainActor func fireLast() {
        guard let action = scheduledActions.last else { return }
        scheduledActions.removeLast()
        action()
    }

    @MainActor func fire(delay: TimeInterval) {
        guard let index = scheduledDelays.firstIndex(of: delay) else { return }
        scheduledDelays.remove(at: index)
        let action = scheduledActions.remove(at: index)
        action()
    }
}

// MARK: - WidgetDecouplingTests

@MainActor
// swiftlint:disable:next type_body_length
final class WidgetDecouplingTests: XCTestCase {

    // swiftlint:disable large_tuple
    private func makeComponents(
        inactivityTimer: any InactivityTimer = FakeInactivityTimer(),
        widgetHideDelay: TimeInterval? = nil,
        alertPresenter: (any AlertPresenter)? = nil
    ) -> (
        coordinator: SessionCoordinator,
        settingsStore: SettingsStore,
        scheduler: WidgetTestHideScheduler,
        fpc: FloatingPanelController
    ) {
        let suiteName = "WidgetDecouple.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "coachingEnabled")
        let settingsStore = SettingsStore(userDefaults: defaults)
        if let delay = widgetHideDelay {
            settingsStore.widgetHideDelaySeconds = delay
        }
        let micMonitor = MicMonitor(provider: MinimalCoreAudioProvider())
        let coordinator = SessionCoordinator(
            micMonitor: micMonitor,
            settingsStore: settingsStore,
            inactivityTimer: inactivityTimer
        )
        let scheduler = WidgetTestHideScheduler()
        let resolvedPresenter = alertPresenter ?? WidgetTestAlertPresenter()
        let fpc = FloatingPanelController(
            sessionCoordinator: coordinator,
            alertPresenter: resolvedPresenter,
            hideScheduler: scheduler,
            settingsStore: settingsStore
        )
        return (coordinator, settingsStore, scheduler, fpc)
    }
    // swiftlint:enable large_tuple

    // MARK: - T17: widgetHideDelaySeconds default is 4

    func testWidgetHideDelaySeconds_DefaultIs4() {
        let suiteName = "WD-default.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(store.widgetHideDelaySeconds, 4.0, accuracy: 0.001,
                       "widgetHideDelaySeconds must default to 4.0 seconds (AC-2)")
    }

    // MARK: - T18: inactivityThresholdSeconds default is 15

    func testInactivityThresholdSeconds_DefaultIs15() {
        let suiteName = "IT-default.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(store.inactivityThresholdSeconds, 15.0, accuracy: 0.001,
                       "inactivityThresholdSeconds must default to 15.0 seconds (AC-1)")
    }

    // MARK: - T19: Token arrival → hide scheduler armed with widgetHideDelaySeconds

    func testTokenArrival_ArmsHideScheduler_WithWidgetHideDelaySetting() async throws {
        let fakeTimer = FakeInactivityTimer()
        let (coordinator, _, scheduler, fpc) = makeComponents(
            inactivityTimer: fakeTimer,
            widgetHideDelay: 7.0
        )

        let yieldingFactory = YieldingAppleBackendFactory()
        let engineProvider = ProbeTestEngineProvider()
        let pipeline = AudioPipeline(provider: engineProvider)
        let fakeLD = FakeLanguageDetector()
        let locales = FakeSupportedLocalesProvider()
        locales.locales = [Locale(identifier: "en-US")]

        let wiring = SessionWiring(
            audioPipeline: pipeline,
            languageDetector: fakeLD,
            appleBackendFactory: yieldingFactory,
            parakeetBackendFactory: TestParakeetBackendFactory(),
            supportedLocalesProvider: locales,
            resumePipelineProvider: nil
        )
        coordinator.wiring = wiring

        fpc.start()
        coordinator.start()

        let consumer = FakeTokenConsumer()
        coordinator.addConsumer(consumer)
        coordinator.micActivated()
        if let task = coordinator.sessionWiringTask { await task.value }

        XCTAssertEqual(fpc.panelState, .visible)

        let tokenExp = XCTestExpectation(description: "token consumed")
        consumer.onReceiveToken = { tokenExp.fulfill() }
        yieldingFactory.stubbedBackend.yield(
            TranscribedToken(token: "hello", startTime: 0, endTime: 0.4, isFinal: true)
        )
        await fulfillment(of: [tokenExp], timeout: 2.0)

        // FPC must have scheduled a hide via lastTokenArrival subscription
        XCTAssertNotNil(scheduler.lastScheduledDelay,
                        "Hide scheduler must be armed on token arrival (token-silence decoupling)")
        if let delay = scheduler.lastScheduledDelay {
            XCTAssertEqual(delay, 7.0, accuracy: 0.001,
                           "Hide delay must use widgetHideDelaySeconds=7.0, not hardcoded 5.0 (AC-5)")
        }
    }

    // MARK: - T20: Session end without tokens → widget hides immediately (no fade)

    func testSessionEnd_WithoutPriorTokens_HidesWidget_Immediately() async {
        let (coordinator, _, scheduler, fpc) = makeComponents()
        fpc.start()
        coordinator.start()

        coordinator.micActivated()
        await Task.yield()
        XCTAssertEqual(fpc.panelState, .visible)

        coordinator.micDeactivated()
        await Task.yield()

        // Widget must not remain visible after session ends
        XCTAssertNotEqual(fpc.panelState, .visible,
                          "Panel must not remain visible after session ends with no tokens (AC-5)")
        // And no fade timer should have been scheduled (session-end is now immediate hide)
        // since token-silence timer is the primary hide mechanism
        XCTAssertEqual(scheduler.scheduledDelays.count, 0,
                       "Session end without tokens must hide immediately, not schedule a fade")
    }

    // MARK: - T-FIX-1: Widget reshows on token arrival after silence-hide (AC-FIX-1)

    func testWidgetReshowsOnTokenArrival_AfterSilenceHide() async throws {
        let fakeTimer = FakeInactivityTimer()
        let (coordinator, _, scheduler, fpc) = makeComponents(
            inactivityTimer: fakeTimer,
            widgetHideDelay: 4.0
        )

        let yieldingFactory = YieldingAppleBackendFactory()
        let engineProvider = ProbeTestEngineProvider()
        let pipeline = AudioPipeline(provider: engineProvider)
        let fakeLD = FakeLanguageDetector()
        let locales = FakeSupportedLocalesProvider()
        locales.locales = [Locale(identifier: "en-US")]

        coordinator.wiring = SessionWiring(
            audioPipeline: pipeline,
            languageDetector: fakeLD,
            appleBackendFactory: yieldingFactory,
            parakeetBackendFactory: TestParakeetBackendFactory(),
            supportedLocalesProvider: locales
        )

        fpc.start()
        coordinator.start()

        let consumer = FakeTokenConsumer()
        coordinator.addConsumer(consumer)
        coordinator.micActivated()
        if let task = coordinator.sessionWiringTask { await task.value }
        XCTAssertEqual(fpc.panelState, .visible)

        // First token → hide timer armed
        let tokenExp1 = XCTestExpectation(description: "first token")
        consumer.onReceiveToken = { tokenExp1.fulfill() }
        yieldingFactory.stubbedBackend.yield(
            TranscribedToken(token: "hello", startTime: 0, endTime: 0.4, isFinal: true)
        )
        await fulfillment(of: [tokenExp1], timeout: 2.0)

        // Silence timer fires → panel hides
        scheduler.fireLast()
        XCTAssertEqual(fpc.panelState, .hidden, "Panel must hide after silence timer fires")

        let countBeforeReshow = scheduler.scheduledDelays.count

        // Second token while session still active → panel must reappear
        let tokenExp2 = XCTestExpectation(description: "second token")
        consumer.onReceiveToken = { tokenExp2.fulfill() }
        yieldingFactory.stubbedBackend.yield(
            TranscribedToken(token: "world", startTime: 0.5, endTime: 0.9, isFinal: true)
        )
        await fulfillment(of: [tokenExp2], timeout: 2.0)
        await Task.yield()

        XCTAssertEqual(fpc.panelState, .visible,
                       "Widget must reappear on token while session is still active (AC-FIX-1)")
        XCTAssertGreaterThan(scheduler.scheduledDelays.count, countBeforeReshow,
                             "New hide timer must be scheduled after reshow")
    }

    // MARK: - T-FIX-2: Widget does not reshow after X-button dismiss (AC-FIX-2)

    func testWidgetDoesNotReshow_AfterDismiss() async throws {
        let fakeTimer = FakeInactivityTimer()
        let (coordinator, _, _, fpc) = makeComponents(
            inactivityTimer: fakeTimer,
            widgetHideDelay: 4.0,
            alertPresenter: ConfirmingWidgetAlertPresenter()
        )

        let yieldingFactory = YieldingAppleBackendFactory()
        let engineProvider = ProbeTestEngineProvider()
        let pipeline = AudioPipeline(provider: engineProvider)
        let fakeLD = FakeLanguageDetector()
        let locales = FakeSupportedLocalesProvider()
        locales.locales = [Locale(identifier: "en-US")]

        coordinator.wiring = SessionWiring(
            audioPipeline: pipeline,
            languageDetector: fakeLD,
            appleBackendFactory: yieldingFactory,
            parakeetBackendFactory: TestParakeetBackendFactory(),
            supportedLocalesProvider: locales
        )

        fpc.start()
        coordinator.start()

        coordinator.micActivated()
        if let task = coordinator.sessionWiringTask { await task.value }
        XCTAssertEqual(fpc.panelState, .visible)

        // User dismisses via X-button
        fpc.requestDismiss()
        XCTAssertNotEqual(fpc.panelState, .visible, "Panel must not be visible after confirmed dismiss")

        // Simulate a stale lastTokenArrival signal arriving AFTER dismiss
        coordinator.lastTokenArrival = Date()
        await Task.yield()

        XCTAssertNotEqual(fpc.panelState, .visible,
                          "Widget must NOT reshow after dismiss, even on stale token signals (AC-FIX-2)")
    }

    // MARK: - T-FIX2-1: X-button dismiss finalizes session immediately (AC-FIX2-1)

    func testRequestDismiss_FinalizesSession_OnConfirmedDismiss() async throws {
        let fakeTimer = FakeInactivityTimer()
        let (coordinator, _, _, fpc) = makeComponents(
            inactivityTimer: fakeTimer,
            widgetHideDelay: 4.0,
            alertPresenter: ConfirmingWidgetAlertPresenter()
        )

        let yieldingFactory = YieldingAppleBackendFactory()
        let engineProvider = ProbeTestEngineProvider()
        let pipeline = AudioPipeline(provider: engineProvider)
        let fakeLD = FakeLanguageDetector()
        let locales = FakeSupportedLocalesProvider()
        locales.locales = [Locale(identifier: "en-US")]

        coordinator.wiring = SessionWiring(
            audioPipeline: pipeline,
            languageDetector: fakeLD,
            appleBackendFactory: yieldingFactory,
            parakeetBackendFactory: TestParakeetBackendFactory(),
            supportedLocalesProvider: locales
        )

        fpc.start()
        coordinator.start()
        coordinator.micActivated()
        if let task = coordinator.sessionWiringTask { await task.value }
        XCTAssertEqual(fpc.panelState, .visible, "Panel must be visible after session start")

        var endedSessions: [EndedSession] = []
        coordinator.onSessionEnded { session in
            endedSessions.append(session)
        }

        fpc.requestDismiss()

        XCTAssertEqual(endedSessions.count, 1,
                       "Session must be finalized synchronously on confirmed dismiss (AC-FIX2-1)")
        XCTAssertEqual(coordinator.lastEndReason, .xButton,
                       "Session end reason must be .xButton (AC-FIX2-2)")
        XCTAssertEqual(coordinator.state, .idle,
                       "Coordinator must be idle after X-button dismiss (AC-FIX2-1)")

        // AC-FIX2-3: stale token signal must not trigger reshow after dismiss
        coordinator.lastTokenArrival = Date()
        await Task.yield()
        XCTAssertNotEqual(fpc.panelState, .visible,
                          "Widget must not reshow after X-button dismiss (AC-FIX2-3)")
    }

    // MARK: - T-FIX-3: Widget does not reshow when session is idle (AC-FIX-3)

    func testWidgetDoesNotReshow_WhenSessionIdle() async {
        let (coordinator, _, scheduler, fpc) = makeComponents()
        fpc.start()
        coordinator.start()

        // Session is idle — never activated; panelState starts .hidden
        XCTAssertEqual(fpc.panelState, .hidden)

        // Simulate stale lastTokenArrival while session is idle (tests the idle-state guard in handleTokenArrival)
        coordinator.lastTokenArrival = Date()
        await Task.yield()

        XCTAssertEqual(fpc.panelState, .hidden,
                       "Widget must not reshow when session is idle — no active session (AC-FIX-3)")
        XCTAssertEqual(scheduler.scheduledDelays.count, 0,
                       "No hide timer must be scheduled when session is idle")
    }

    // MARK: - T-FIX3-A.5.1: Widget stays hidden on mic-on, shows only on first token (AC-FIX3-A1)

    func testWidgetStaysHiddenOnMicOn_UntilFirstToken() async {
        let (coordinator, _, _, fpc) = makeComponents()
        fpc.start()
        coordinator.start()

        coordinator.micActivated()
        await Task.yield()

        XCTAssertEqual(fpc.panelState, .hidden,
                       "Widget must remain hidden on mic-on — token arrival is the trigger (AC-FIX3-A1)")

        coordinator.lastTokenArrival = Date()
        await Task.yield()

        XCTAssertEqual(fpc.panelState, .visible,
                       "Widget must appear on first token arrival (AC-FIX3-A1)")
    }

    // MARK: - T-FIX3-A.5.2: Widget clears prior dismiss on new session, shows on token (AC-FIX3-A2)

    func testWidgetClearsPriorDismissOnNewSession() async {
        let (coordinator, _, _, fpc) = makeComponents(
            alertPresenter: ConfirmingWidgetAlertPresenter()
        )
        fpc.start()
        coordinator.start()

        // Session 1: activate, show via token, then dismiss
        coordinator.micActivated()
        await Task.yield()
        coordinator.lastTokenArrival = Date()
        await Task.yield()
        XCTAssertEqual(fpc.panelState, .visible, "Panel must be visible after token in session 1")

        fpc.requestDismiss()
        // requestDismiss → requestFinalize → session ends → handleSessionIdle → .hidden

        // Session 2: dismiss state must be cleared, panel stays hidden until token
        coordinator.micActivated()
        await Task.yield()

        XCTAssertEqual(fpc.panelState, .hidden,
                       "Dismissed state must clear on new session — panel stays hidden until token (AC-FIX3-A2)")

        coordinator.lastTokenArrival = Date()
        await Task.yield()

        XCTAssertEqual(fpc.panelState, .visible,
                       "Widget must appear on token in new session after prior dismiss (AC-FIX3-A2)")
    }

    // MARK: - T-FIX3-B1: activityState .waiting → .counting on token, reverts after 1.5s (AC-FIX3-B1)

    func testActivityState_TransitionsToCountingOnToken_AndWaitingAfter1500ms() async {
        let fakeTimer = FakeInactivityTimer()
        let (coordinator, _, scheduler, fpc) = makeComponents(
            inactivityTimer: fakeTimer,
            widgetHideDelay: 4.0
        )

        fpc.start()
        coordinator.start()
        coordinator.micActivated()
        await Task.yield()

        XCTAssertEqual(fpc.viewModel.activityState, .waiting,
                       "Activity state must be .waiting before any token (AC-FIX3-B1)")

        coordinator.lastTokenArrival = Date()
        await Task.yield()

        XCTAssertEqual(fpc.viewModel.activityState, .counting,
                       "Activity state must be .counting immediately after token arrival (AC-FIX3-B1)")

        // Fire the 1.5s counting timeout (scheduled by handleTokenArrival in Part B impl)
        scheduler.fire(delay: 1.5)

        XCTAssertEqual(fpc.viewModel.activityState, .waiting,
                       "Activity state must revert to .waiting after 1.5s counting timeout (AC-FIX3-B1)")
    }

    // MARK: - T-FIX3-B3: totalTokens increments per token, resets on session end (AC-FIX3-B3)

    func testTotalTokens_IncrementsPerToken_ResetsOnSessionEnd() async throws {
        let fakeTimer = FakeInactivityTimer()
        let (coordinator, _, _, fpc) = makeComponents(inactivityTimer: fakeTimer)

        let yieldingFactory = YieldingAppleBackendFactory()
        let engineProvider = ProbeTestEngineProvider()
        let pipeline = AudioPipeline(provider: engineProvider)
        let fakeLD = FakeLanguageDetector()
        let locales = FakeSupportedLocalesProvider()
        locales.locales = [Locale(identifier: "en-US")]

        coordinator.wiring = SessionWiring(
            audioPipeline: pipeline,
            languageDetector: fakeLD,
            appleBackendFactory: yieldingFactory,
            parakeetBackendFactory: TestParakeetBackendFactory(),
            supportedLocalesProvider: locales
        )

        fpc.start()
        coordinator.start()

        let consumer = FakeTokenConsumer()
        coordinator.addConsumer(consumer)
        coordinator.micActivated()
        if let task = coordinator.sessionWiringTask { await task.value }

        let tokenExp1 = XCTestExpectation(description: "first token")
        consumer.onReceiveToken = { tokenExp1.fulfill() }
        yieldingFactory.stubbedBackend.yield(
            TranscribedToken(token: "hello", startTime: 0, endTime: 0.4, isFinal: true)
        )
        await fulfillment(of: [tokenExp1], timeout: 2.0)
        await Task.yield()

        XCTAssertEqual(fpc.viewModel.totalTokens, 1,
                       "totalTokens must be 1 after first token (AC-FIX3-B3)")

        let tokenExp2 = XCTestExpectation(description: "second token")
        consumer.onReceiveToken = { tokenExp2.fulfill() }
        yieldingFactory.stubbedBackend.yield(
            TranscribedToken(token: "world", startTime: 0.5, endTime: 0.9, isFinal: true)
        )
        await fulfillment(of: [tokenExp2], timeout: 2.0)
        await Task.yield()

        XCTAssertEqual(fpc.viewModel.totalTokens, 2,
                       "totalTokens must be 2 after second token (AC-FIX3-B3)")

        coordinator.micDeactivated()
        await Task.yield()

        XCTAssertEqual(fpc.viewModel.totalTokens, 0,
                       "totalTokens must reset to 0 after session ends (AC-FIX3-B3)")
    }

    // MARK: - T21: FPC subscribes to sessionCoordinator.$lastTokenArrival

    func testFPC_Subscribes_ToLastTokenArrival_OnStart() async throws {
        let fakeTimer = FakeInactivityTimer()
        let (coordinator, _, scheduler, fpc) = makeComponents(
            inactivityTimer: fakeTimer,
            widgetHideDelay: 6.0
        )

        let yieldingFactory = YieldingAppleBackendFactory()
        let engineProvider = ProbeTestEngineProvider()
        let pipeline = AudioPipeline(provider: engineProvider)
        let fakeLD = FakeLanguageDetector()
        let locales = FakeSupportedLocalesProvider()
        locales.locales = [Locale(identifier: "en-US")]

        let wiring = SessionWiring(
            audioPipeline: pipeline,
            languageDetector: fakeLD,
            appleBackendFactory: yieldingFactory,
            parakeetBackendFactory: TestParakeetBackendFactory(),
            supportedLocalesProvider: locales,
            resumePipelineProvider: nil
        )
        coordinator.wiring = wiring

        fpc.start()

        let consumer = FakeTokenConsumer()
        coordinator.addConsumer(consumer)
        coordinator.micActivated()
        if let task = coordinator.sessionWiringTask { await task.value }

        let countBefore = scheduler.scheduledDelays.count

        let tokenExp = XCTestExpectation(description: "token consumed")
        consumer.onReceiveToken = { tokenExp.fulfill() }
        yieldingFactory.stubbedBackend.yield(
            TranscribedToken(token: "test", startTime: 0, endTime: 0.3, isFinal: true)
        )
        await fulfillment(of: [tokenExp], timeout: 2.0)

        XCTAssertGreaterThan(scheduler.scheduledDelays.count, countBefore,
                             "FPC must react to lastTokenArrival changes and schedule the hide timer (Combine subscription)")
    }
}
