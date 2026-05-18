// swiftlint:disable file_length type_body_length
import CoreAudio
import XCTest
@testable import TalkCoach

// MARK: - Test doubles

private final class LifecycleAlertPresenter: AlertPresenter, @unchecked Sendable {
    nonisolated(unsafe) var stubbedResult: Bool = true
    nonisolated(unsafe) private(set) var callCount = 0
    @MainActor func presentDismissConfirmation() -> Bool {
        callCount += 1
        return stubbedResult
    }
}

private struct LifecycleSchedulerEntry {
    let delay: TimeInterval
    let action: @MainActor @Sendable () -> Void
    let token: HideSchedulerToken
}

private final class LifecycleHideScheduler: HideScheduler, @unchecked Sendable {
    nonisolated(unsafe) private(set) var entries: [LifecycleSchedulerEntry] = []
    nonisolated(unsafe) private(set) var cancelCallCount = 0

    @MainActor func schedule(
        delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void
    ) -> HideSchedulerToken {
        let token = HideSchedulerToken()
        entries.append(LifecycleSchedulerEntry(delay: delay, action: action, token: token))
        return token
    }

    @MainActor func cancel(_ token: HideSchedulerToken) {
        cancelCallCount += 1
        entries.removeAll { $0.token == token }
    }

    @MainActor func fire(delay matching: TimeInterval) {
        guard let idx = entries.firstIndex(where: { $0.delay == matching }) else { return }
        let entry = entries.remove(at: idx)
        entry.action()
    }

    @MainActor func fireAll() {
        let pending = entries
        entries.removeAll()
        for entry in pending { entry.action() }
    }

    func hasEntry(delay: TimeInterval) -> Bool {
        entries.contains { $0.delay == delay }
    }

    var entryCount: Int { entries.count }
}

// MARK: - FloatingPanelLifecycleTests

@MainActor
final class FloatingPanelLifecycleTests: XCTestCase {

    private var coordinator: SessionCoordinator!
    private var scheduler: LifecycleHideScheduler!
    private var alertPresenter: LifecycleAlertPresenter!
    private var sut: FloatingPanelController!

    private func makeComponents(
        reducedMotion: Bool = true,
        now nowProvider: @escaping () -> Date = { Date() },
        runAnimation: @escaping (TimeInterval, @escaping () -> Void) -> Void = { _, block in block() }
    ) {
        let suiteName = "LifecycleTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "coachingEnabled")
        let settingsStore = SettingsStore(userDefaults: defaults)
        let micMonitor = MicMonitor(provider: MinimalCoreAudioProvider())
        coordinator = SessionCoordinator(micMonitor: micMonitor, settingsStore: settingsStore)
        scheduler = LifecycleHideScheduler()
        alertPresenter = LifecycleAlertPresenter()
        sut = FloatingPanelController(
            sessionCoordinator: coordinator,
            alertPresenter: alertPresenter,
            hideScheduler: scheduler,
            settingsStore: settingsStore,
            now: nowProvider,
            reducedMotionProvider: { reducedMotion },
            runAnimation: runAnimation
        )
    }

    private func activateSession() async {
        coordinator.start()
        coordinator.micActivated()
        await Task.yield()
    }

    private func showPanel() async {
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
    }

    private func endSession() async {
        coordinator.micDeactivated()
        await Task.yield()
    }

    // MARK: - Group 1: Engine-ready show

    func testEngineReady_ShowsPanel_WhenHidden_DuringActiveSession() async {
        makeComponents()
        sut.start()
        await activateSession()
        XCTAssertEqual(sut.panelState, .hidden, "Panel must be hidden before engine-ready")

        await showPanel()

        XCTAssertEqual(sut.panelState, .visible,
                       "Panel must become .visible on engine-ready during active session")
    }

    func testEngineReady_NoShow_WhenSessionIdle() async {
        makeComponents()
        sut.start()
        coordinator.start()
        // Do NOT activate session

        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        XCTAssertEqual(sut.panelState, .hidden,
                       "Panel must NOT show on engine-ready when session is idle")
    }

    func testEngineReady_WhileAlreadyVisible_DoesNotHideAndReshow() async {
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()
        XCTAssertEqual(sut.panelState, .visible)

        // Second engine-ready while already visible
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        XCTAssertEqual(sut.panelState, .visible,
                       "Panel must remain .visible on duplicate engine-ready — no flicker")
    }

    // MARK: - Group 2: Linger sequence on session end

    func testSessionEnd_WhileVisible_StartsLingerFull() async {
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()
        XCTAssertEqual(sut.panelState, .visible)

        await endSession()

        XCTAssertEqual(sut.panelState, .lingerFull,
                       "Session end while visible must start lingerFull (3-second stay)")
    }

    func testSessionEnd_WhileHidden_StaysHidden() async {
        makeComponents()
        sut.start()
        await activateSession()
        // Never showed panel

        await endSession()

        XCTAssertEqual(sut.panelState, .hidden,
                       "Session end while hidden must stay hidden — no linger triggered")
    }

    func testLingerFull_TimerFires_WithReducedMotion_HidesPanel() async {
        makeComponents(reducedMotion: true)
        sut.start()
        await activateSession()
        await showPanel()
        await endSession()
        XCTAssertEqual(sut.panelState, .lingerFull)

        scheduler.fire(delay: 3.0)

        XCTAssertEqual(sut.panelState, .hidden,
                       "lingerFull timer with reducedMotion=true must immediately hide panel")
    }

    func testLingerFull_TimerFires_WithoutReducedMotion_StartsLingerFade() async {
        makeComponents(reducedMotion: false)
        sut.start()
        await activateSession()
        await showPanel()
        await endSession()
        XCTAssertEqual(sut.panelState, .lingerFull)

        scheduler.fire(delay: 3.0)

        XCTAssertEqual(sut.panelState, .lingerFade,
                       "lingerFull timer with reducedMotion=false must start lingerFade")
    }

    func testLingerFade_TimerFires_HidesPanel() async {
        makeComponents(reducedMotion: false)
        sut.start()
        await activateSession()
        await showPanel()
        await endSession()

        scheduler.fire(delay: 3.0)
        XCTAssertEqual(sut.panelState, .lingerFade)

        scheduler.fire(delay: 2.0)
        XCTAssertEqual(sut.panelState, .hidden,
                       "lingerFade timer (2s) must hide panel when it fires")
    }

    func testLingerComplete_ResetsViewModel() async {
        makeComponents(reducedMotion: true)
        sut.start()
        await activateSession()
        await showPanel()
        sut.viewModel.totalTokens = 5
        await endSession()

        scheduler.fire(delay: 3.0)

        XCTAssertEqual(sut.viewModel.totalTokens, 0,
                       "Linger completion must call resetViewModel, resetting totalTokens to 0")
    }

    // MARK: - Group 3: Hover during lingerFull

    func testHoverEntered_DuringLingerFull_CancelsTimer() async {
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()
        await endSession()
        XCTAssertEqual(sut.panelState, .lingerFull)
        let cancelsBefore = scheduler.cancelCallCount

        sut.handleHoverEntered()

        XCTAssertGreaterThan(scheduler.cancelCallCount, cancelsBefore,
                             "handleHoverEntered must cancel the lingerFull countdown timer")
    }

    func testHoverExited_AfterHoverEntered_RearmsLingerFullTimer() async {
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()
        await endSession()

        sut.handleHoverEntered()
        let countAfterEnter = scheduler.entryCount

        sut.handleHoverExited()

        XCTAssertGreaterThan(scheduler.entryCount, countAfterEnter,
                             "handleHoverExited must rearm the lingerFull timer")
        XCTAssertEqual(sut.panelState, .lingerFull,
                       "Panel must stay .lingerFull after hover-exit re-arm")
    }

    func testMultiCycle_Hover_LingerFull() async {
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()
        await endSession()

        // Three enter/exit cycles
        for _ in 0..<3 {
            sut.handleHoverEntered()
            sut.handleHoverExited()
        }

        XCTAssertEqual(sut.panelState, .lingerFull,
                       "Panel must stay .lingerFull through multiple hover cycles")
    }

    func testHoverExited_SchedulesRemainingTime_BasedOnElapsed() async {
        var currentTime = Date(timeIntervalSinceReferenceDate: 0)
        makeComponents(now: { currentTime })
        sut.start()
        await activateSession()
        await showPanel()
        await endSession()
        XCTAssertEqual(sut.panelState, .lingerFull)

        sut.handleHoverEntered()

        // Advance time by 1 second
        currentTime = Date(timeIntervalSinceReferenceDate: 1.0)
        sut.handleHoverExited()

        // Remaining time should be 3 - 1 = 2 seconds
        XCTAssertTrue(scheduler.hasEntry(delay: 2.0),
                      "After 1s hover pause, lingerFull must rearm with remaining 2.0s")
    }

    // MARK: - Group 4: Hover during lingerFade

    func testHoverEntered_DuringLingerFade_CancelsFade_RestartsLingerFull() async {
        makeComponents(reducedMotion: false)
        sut.start()
        await activateSession()
        await showPanel()
        await endSession()
        scheduler.fire(delay: 3.0)
        XCTAssertEqual(sut.panelState, .lingerFade)

        sut.handleHoverEntered()
        sut.handleHoverExited()

        XCTAssertEqual(sut.panelState, .lingerFull,
                       "Hover during lingerFade must cancel fade and restart lingerFull at 3s")
        XCTAssertTrue(scheduler.hasEntry(delay: 3.0),
                      "lingerFull must be rearmed at full 3.0s after hover during lingerFade")
    }

    // MARK: - Group 5: Phase G (engine-ready during linger)

    func testEngineReady_DuringLingerFull_TransitionsToVisible_InPlace() async {
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()
        await endSession()
        XCTAssertEqual(sut.panelState, .lingerFull)
        sut.viewModel.totalTokens = 3  // set to verify Phase G resets this
        let cancelsBefore = scheduler.cancelCallCount

        coordinator.micActivated()
        await Task.yield()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        XCTAssertEqual(sut.panelState, .visible,
                       "Phase G: engine-ready during lingerFull must transition to .visible (in-place content swap)")
        XCTAssertEqual(sut.viewModel.totalTokens, 0,
                       "Phase G: viewModel.totalTokens must reset to 0")
        XCTAssertTrue(sut.viewModel.isSessionActive,
                      "Phase G: viewModel.isSessionActive must be true")
        XCTAssertEqual(sut.viewModel.activityState, .waiting,
                       "Phase G: activityState must start as .waiting")
        XCTAssertGreaterThan(scheduler.cancelCallCount, cancelsBefore,
                             "Phase G: lingerFull hideToken must be cancelled")
    }

    func testEngineReady_DuringLingerFade_CancelsFade_TransitionsToVisible() async {
        makeComponents(reducedMotion: false)
        sut.start()
        await activateSession()
        await showPanel()
        await endSession()
        scheduler.fire(delay: 3.0)
        XCTAssertEqual(sut.panelState, .lingerFade)
        sut.viewModel.totalTokens = 2  // set to verify Phase G resets this
        let cancelsBefore = scheduler.cancelCallCount

        coordinator.micActivated()
        await Task.yield()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        XCTAssertEqual(sut.panelState, .visible,
                       "Phase G: engine-ready during lingerFade must transition to .visible")
        XCTAssertEqual(sut.viewModel.totalTokens, 0,
                       "Phase G: viewModel.totalTokens must reset to 0")
        XCTAssertEqual(sut.viewModel.activityState, .waiting,
                       "Phase G: activityState must start as .waiting")
        XCTAssertGreaterThan(scheduler.cancelCallCount, cancelsBefore,
                             "Phase G: lingerFade hideToken must be cancelled")
    }

    // MARK: - Group 6: Dismiss during linger

    func testRequestDismiss_DuringLingerFull_Confirms_SetsDismissed() async {
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()
        await endSession()
        XCTAssertEqual(sut.panelState, .lingerFull)
        alertPresenter.stubbedResult = true

        sut.requestDismiss()

        XCTAssertEqual(sut.panelState, .dismissed,
                       "Confirmed dismiss during lingerFull must set panelState to .dismissed")
    }

    func testRequestDismiss_DuringLingerFull_Cancels_StaysLingerFull() async {
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()
        await endSession()
        XCTAssertEqual(sut.panelState, .lingerFull)
        alertPresenter.stubbedResult = false

        sut.requestDismiss()

        XCTAssertEqual(sut.panelState, .lingerFull,
                       "Canceled dismiss during lingerFull must leave panel in .lingerFull")
    }

    // MARK: - Group 7: Token silence activity state

    func testIsInTokenSilence_True_SetsActivityState_Waiting() async {
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()
        sut.viewModel.activityState = .counting

        coordinator.isInTokenSilence = true
        await Task.yield()

        XCTAssertEqual(sut.viewModel.activityState, .waiting,
                       "isInTokenSilence=true must set activityState to .waiting")
    }

    func testIsInTokenSilence_False_DoesNotAffectActivityState() async {
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()
        sut.viewModel.activityState = .counting

        coordinator.isInTokenSilence = false
        await Task.yield()

        XCTAssertEqual(sut.viewModel.activityState, .counting,
                       "isInTokenSilence=false must NOT change activityState (only true triggers .waiting)")
    }

    func testEngineReady_InitialActivityState_IsWaiting() async {
        makeComponents()
        sut.start()
        await activateSession()
        sut.viewModel.activityState = .counting  // set to verify engine-ready overrides to .waiting

        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        XCTAssertEqual(sut.viewModel.activityState, .waiting,
                       "Engine-ready must set initial activityState to .waiting, not .counting")
    }

    func testLastTokenArrival_SetsActivityState_Counting() async {
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()
        // Establish .waiting state
        coordinator.isInTokenSilence = true
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .waiting)

        coordinator.lastTokenArrival = Date()
        await Task.yield()

        XCTAssertEqual(sut.viewModel.activityState, .counting,
                       "Token arrival must set activityState to .counting")
    }

    // MARK: - Group 8: TrackingContentView hover callback wiring

    func testTrackingContentView_HoverEnteredCallback_InvokesHandler() {
        let view = TrackingContentView()
        var enteredFired = false
        view.onHoverEntered = { enteredFired = true }

        // .mouseEntered/.mouseExited cannot be synthesised with mouseEvent(with:) — they are
        // tracking-area events created by the window server. Use .mouseMoved (valid for mouseEvent)
        // since our override ignores the event parameter entirely.
        let fakeEvent = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )!
        view.mouseEntered(with: fakeEvent)

        XCTAssertTrue(enteredFired,
                      "TrackingContentView.mouseEntered must invoke onHoverEntered callback")
    }

    func testTrackingContentView_HoverExitedCallback_InvokesHandler() {
        let view = TrackingContentView()
        var exitedFired = false
        view.onHoverExited = { exitedFired = true }

        let fakeEvent = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )!
        view.mouseExited(with: fakeEvent)

        XCTAssertTrue(exitedFired,
                      "TrackingContentView.mouseExited must invoke onHoverExited callback")
    }

    // MARK: - Group 10: Bug B — linger fade animation and alpha reset

    func testLingerFullTimer_NonReducedMotion_RunsAnimationWithDuration2() async {
        // Bug B fix: lingerFullTimerFired() must call runAnimation(2.0, block) in the
        // non-reducedMotion path. The injected closure captures arguments for verification.
        var capturedDuration: TimeInterval?
        var capturedBlock: (() -> Void)?
        makeComponents(reducedMotion: false, runAnimation: { duration, block in
            capturedDuration = duration
            capturedBlock = block
        })
        sut.start()
        await activateSession()
        await showPanel()
        await endSession()
        XCTAssertEqual(sut.panelState, .lingerFull)

        scheduler.fire(delay: 3.0) // lingerFullTimerFired() runs

        XCTAssertEqual(capturedDuration, 2.0,
                       "lingerFade animation must have exactly 2.0s duration")
        XCTAssertNotNil(capturedBlock,
                        "runAnimation must be called with a non-nil block")

        // Verify the block sets panel alpha to 0 (fade-to-invisible)
        capturedBlock?()
        XCTAssertEqual(sut.panelWindow?.alphaValue, 0.0,
                       "Animation block must set panel alphaValue to 0 for fade effect")
    }

    func testCompleteLingerHide_ResetsAlphaToOne_ForNextShow() async {
        // Bug B fix: completeLingerHide() must reset panel alphaValue to 1.0 after hiding,
        // so the next session's showPanel() starts at full opacity, not 0.0 from the fade.
        makeComponents(reducedMotion: true) // reduced motion skips animation, fires hide directly
        sut.start()
        await activateSession()
        await showPanel()
        await endSession()
        XCTAssertEqual(sut.panelState, .lingerFull)

        // Simulate alpha being at 0.0 (as if a fade animation ran and ended)
        sut.panelWindow?.alphaValue = 0.0

        scheduler.fire(delay: 3.0) // reduced-motion path → completeLingerHide()

        XCTAssertEqual(sut.panelWindow?.alphaValue, 1.0,
                       "completeLingerHide must reset alphaValue to 1.0 so next show starts opaque")
    }

    // MARK: - Group 9: Dismissed state invariants

    func testDismissed_ClearedAtMicOn_PanelHiddenUntilEngineReady() async {
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()
        alertPresenter.stubbedResult = true
        sut.requestDismiss()
        XCTAssertEqual(sut.panelState, .dismissed)

        // New session: mic-on clears .dismissed
        coordinator.micActivated()
        await Task.yield()
        XCTAssertEqual(sut.panelState, .hidden,
                       ".dismissed must be cleared to .hidden when new session starts (mic-on)")

        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.panelState, .visible,
                       "Panel must show on engine-ready after dismiss cleared by new session")
    }
}
// swiftlint:enable file_length type_body_length
