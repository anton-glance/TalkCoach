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
final class WidgetDecouplingTests: XCTestCase {

    // swiftlint:disable large_tuple
    private func makeComponents(
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
            settingsStore: settingsStore
        )
        let scheduler = WidgetTestHideScheduler()
        let resolvedPresenter = alertPresenter ?? WidgetTestAlertPresenter()
        let fpc = FloatingPanelController(
            sessionCoordinator: coordinator,
            alertPresenter: resolvedPresenter,
            hideScheduler: scheduler,
            settingsStore: settingsStore,
            reducedMotionProvider: { true }
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

    // MARK: - T20: Session end without tokens → widget shows warming then enters lingerFull (AC-FIX7)

    func testSessionEnd_WithoutPriorTokens_ShowsWarmingThenLingerFull() async {
        let (coordinator, _, _, fpc) = makeComponents()
        fpc.start()
        coordinator.start()

        coordinator.micActivated()
        await Task.yield()
        // AC-FIX7: panel shows immediately on mic-on as .warming
        XCTAssertEqual(fpc.panelState, .visible,
                       "Widget must show .warming on mic-on (AC-FIX7)")
        XCTAssertEqual(fpc.viewModel.activityState, .warming,
                       "activityState must be .warming on mic-on (AC-FIX7)")

        coordinator.micDeactivated()
        await Task.yield()

        // Session ended while visible (warming) → lingerFull
        XCTAssertEqual(fpc.panelState, .lingerFull,
                       "Session end while .warming must start lingerFull, not hide immediately (AC-FIX7)")
    }

    // MARK: - T-FIX-2: Widget does not reshow after X-button dismiss (AC-FIX-2)

    func testWidgetDoesNotReshow_AfterDismiss() async throws {
        let (coordinator, _, _, fpc) = makeComponents(
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

        // Engine-ready triggers panel show (AC-fix6: widget shows on engine-ready, not token)
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(fpc.panelState, .visible,
                       "Panel must be visible after engine-ready before dismiss test begins")

        // User dismisses via X-button
        fpc.requestDismiss()
        XCTAssertNotEqual(fpc.panelState, .visible, "Panel must not be visible after confirmed dismiss")

        // Simulate a stale lastTokenArrival signal arriving AFTER dismiss (FPC ignores this)
        coordinator.lastTokenArrival = Date()
        await Task.yield()

        XCTAssertNotEqual(fpc.panelState, .visible,
                          "Widget must NOT reshow after dismiss, even on stale token signals (AC-FIX-2)")
    }

    // MARK: - T-FIX2-1: X-button dismiss finalizes session immediately (AC-FIX2-1)

    func testRequestDismiss_FinalizesSession_OnConfirmedDismiss() async throws {
        let (coordinator, _, _, fpc) = makeComponents(
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

        // Engine-ready triggers panel show (AC-fix6: widget shows on engine-ready, not token)
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(fpc.panelState, .visible, "Panel must be visible after engine-ready before dismiss test begins")

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

        // AC-FIX2-3: stale lastTokenArrival must not trigger reshow (FPC ignores this signal now)
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

    // MARK: - T-FIX7-A.5.1: Widget shows warming on mic-on, transitions to counting on engine-ready (AC-FIX7)

    func testWidgetShowsWarming_OnMicOn_CountingOnEngineReady() async {
        let (coordinator, _, _, fpc) = makeComponents()
        fpc.start()
        coordinator.start()

        coordinator.micActivated()
        await Task.yield()

        XCTAssertEqual(fpc.panelState, .visible,
                       "Widget must appear immediately on mic-on in .warming state (AC-FIX7)")
        XCTAssertEqual(fpc.viewModel.activityState, .warming,
                       "activityState must be .warming on mic-on (AC-FIX7)")

        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        XCTAssertEqual(fpc.panelState, .visible,
                       "Widget must remain .visible after engine-ready")
        XCTAssertEqual(fpc.viewModel.activityState, .counting,
                       "activityState must transition to .counting on engine-ready (AC-FIX7)")
    }

    // MARK: - T-FIX7-A.5.2: Widget clears prior dismiss on new session, shows warming then counting (AC-FIX7)

    func testWidgetClearsPriorDismissOnNewSession() async {
        let (coordinator, _, _, fpc) = makeComponents(
            alertPresenter: ConfirmingWidgetAlertPresenter()
        )
        fpc.start()
        coordinator.start()

        // Session 1: activate, show via mic-on, then dismiss
        coordinator.micActivated()
        await Task.yield()
        XCTAssertEqual(fpc.panelState, .visible, "Panel must be visible (warming) after mic-on in session 1")

        fpc.requestDismiss()
        // requestDismiss → confirmed → panelState = .dismissed, session finalized

        // Session 2: mic-on clears .dismissed and shows panel immediately as .warming
        coordinator.micActivated()
        await Task.yield()

        XCTAssertEqual(fpc.panelState, .visible,
                       "Dismissed state must clear on new mic-on — panel shows .warming immediately (AC-FIX7)")
        XCTAssertEqual(fpc.viewModel.activityState, .warming,
                       "activityState must be .warming after dismiss-cleared mic-on (AC-FIX7)")

        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        XCTAssertEqual(fpc.viewModel.activityState, .counting,
                       "activityState must transition to .counting on engine-ready after dismiss-cleared session (AC-FIX7)")
    }

    // MARK: - T-FIX3-B3: totalTokens increments per token, resets on session end (AC-FIX3-B3)

    func testTotalTokens_IncrementsPerToken_ResetsOnSessionEnd() async throws {
        let (coordinator, _, scheduler, fpc) = makeComponents()

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

        // Engine-ready triggers panel show (AC-fix6: widget shows on engine-ready, not token)
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(fpc.panelState, .visible, "Panel must be visible before token counting begins")

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

        // Session end while visible → lingerFull. Fire linger timer to complete reset.
        scheduler.fire(delay: 3.0)
        await Task.yield()

        XCTAssertEqual(fpc.viewModel.totalTokens, 0,
                       "totalTokens must reset to 0 after linger sequence completes (AC-FIX3-B3)")
    }

}
