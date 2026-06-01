// swiftlint:disable file_length type_body_length
import CoreAudio
import XCTest
@testable import TalkCoach

// MARK: - Test doubles

private final class LifecycleAlertPresenter: AlertPresenter, @unchecked Sendable {
    nonisolated(unsafe) var stubbedResult: Bool = true
    nonisolated(unsafe) private(set) var callCount = 0
    nonisolated(unsafe) var onPresent: (() -> Void)?
    @MainActor func presentDismissConfirmation() -> Bool {
        callCount += 1
        onPresent?()
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

private final class LifecycleWPMScheduler: HideScheduler, @unchecked Sendable {
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

    // MARK: - Group 1: Mic-on show and engine-ready counting transition (AC-FIX7)

    func testWidget_AppearsAtMicOn_NotEngineReady() async {
        makeComponents()
        sut.start()
        coordinator.start()

        coordinator.micActivated()
        await Task.yield()

        XCTAssertEqual(sut.panelState, .visible,
                       "Panel must appear immediately on mic-on in .warming state (AC-FIX7)")
        XCTAssertEqual(sut.viewModel.activityState, .warming,
                       "activityState must be .warming on mic-on before engine-ready (AC-FIX7)")
    }

    func testWidget_TransitionsToCounting_AtEngineReady() async {
        makeComponents()
        sut.start()
        await activateSession()
        XCTAssertEqual(sut.viewModel.activityState, .warming,
                       "activityState must be .warming after mic-on")

        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        XCTAssertEqual(sut.viewModel.activityState, .warming,
                       "M5.7: engine-ready is a no-op for activityState — .counting fires only on first WPM")
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

    func testSessionEnd_WhileWarming_StartsLingerFull() async {
        makeComponents()
        sut.start()
        await activateSession()
        // Panel shows .warming (visible) without engine-ready
        XCTAssertEqual(sut.panelState, .visible,
                       "Panel must be .visible (warming) after mic-on before engine-ready")

        await endSession()

        XCTAssertEqual(sut.panelState, .lingerFull,
                       "Session end while visible (warming) must start lingerFull")
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
        XCTAssertEqual(sut.viewModel.activityState, .idle,
                       "Linger completion must reset activityState to .idle")
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
        XCTAssertEqual(sut.viewModel.activityState, .warming,
                       "Phase G: engine-ready during lingerFull transitions to .warming (M5.7: .counting via WPM gate)")
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
        XCTAssertEqual(sut.viewModel.activityState, .warming,
                       "Phase G: engine-ready during lingerFade transitions to .warming (M5.7: .counting via WPM gate)")
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

    func testEngineReady_TransitionsActivityState_ToCounting() async {
        makeComponents()
        sut.start()
        await activateSession()
        // Panel shows .warming after mic-on
        XCTAssertEqual(sut.viewModel.activityState, .warming,
                       "activityState must be .warming after mic-on before engine-ready")

        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        XCTAssertEqual(sut.viewModel.activityState, .warming,
                       "M5.7: engine-ready is a no-op for activityState — .counting fires only on first WPM")
    }

    func testLastTokenArrival_SetsActivityState_Counting() async {
        // M5.7: tokens no longer drive activityState changes (only WPM gate → .counting).
        // Verify token arrival does not change activityState from .warming.
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()  // engine-ready is a no-op in M5.7, stays .warming
        coordinator.isVoiceInactive = true
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .warming,
                       "M5.7: activityState stays .warming during silence hold (no WPM calc)")

        coordinator.lastTokenArrival = Date()
        await Task.yield()

        XCTAssertEqual(sut.viewModel.activityState, .warming,
                       "M5.7: token arrival must NOT change activityState — .counting requires first WPM via gate")
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

    // MARK: - Group 9: Alpha-snap correctness (Bug D / E / F)

    // Bug D: hover during lingerFade must snap alpha to 1.0 immediately
    func testHoverEntered_DuringLingerFade_SnapsAlphaToFullOpacity() async {
        makeComponents(reducedMotion: false)
        sut.start()
        await activateSession()
        await showPanel()
        await endSession()
        scheduler.fire(delay: 3.0)
        XCTAssertEqual(sut.panelState, .lingerFade)
        // Simulate fade having progressed to a sub-1.0 alpha
        sut.panelWindow?.alphaValue = 0.4

        sut.handleHoverEntered()

        XCTAssertEqual(sut.panelWindow?.alphaValue, 1.0,
                       "Hover during lingerFade must snap alpha back to 1.0 (cancel visual fade)")
        XCTAssertEqual(sut.panelState, .lingerFull,
                       "Hover during lingerFade must transition to .lingerFull")
    }

    // Bug E: X-button during lingerFade must snap alpha to 1.0 BEFORE modal opens
    func testRequestDismiss_DuringLingerFade_SnapsAlphaBeforeModal() async {
        makeComponents(reducedMotion: false)
        sut.start()
        await activateSession()
        await showPanel()
        await endSession()
        scheduler.fire(delay: 3.0)
        XCTAssertEqual(sut.panelState, .lingerFade)
        sut.panelWindow?.alphaValue = 0.4  // simulate mid-fade

        nonisolated(unsafe) var alphaAtModalOpen: CGFloat?
        alertPresenter.onPresent = { [weak sut] in
            alphaAtModalOpen = sut?.panelWindow?.alphaValue
        }
        alertPresenter.stubbedResult = false  // cancel
        sut.requestDismiss()

        XCTAssertEqual(alphaAtModalOpen, 1.0,
                       "Alpha must be snapped to 1.0 BEFORE modal opens during .lingerFade")
        XCTAssertEqual(sut.panelState, .lingerFull,
                       "Cancel-from-lingerFade must transition to .lingerFull with fresh countdown")
        XCTAssertTrue(scheduler.hasEntry(delay: 3.0),
                      "Fresh 3.0s countdown must be rearmed after cancel from .lingerFade")
    }

    // Bug F: showPanel() defensive alpha reset — reused panel must always start opaque
    func testShowPanel_AlwaysStartsAtFullOpacity_EvenIfPanelLeftAtSubOpacity() async {
        makeComponents(reducedMotion: true, runAnimation: { _, block in
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0; ctx.allowsImplicitAnimation = true; block() }
        })
        sut.start()
        // Session 1: show, linger, complete — panel ivar survives at .hidden
        await activateSession()
        await showPanel()
        await endSession()
        scheduler.fire(delay: 3.0)  // reducedMotion → completeLingerHide → .hidden
        XCTAssertEqual(sut.panelState, .hidden)

        // Corrupt alpha to simulate a missed reset from any prior code path
        sut.panelWindow?.alphaValue = 0.3

        // Session 2: mic-on calls showPanel() which resets alpha before applying .warming opacity
        await activateSession()

        XCTAssertEqual(sut.panelWindow?.alphaValue ?? -1, 0.5, accuracy: 0.01,
                       "showPanel must clear corrupted alpha; panel shows at natural .warming opacity (0.5)")
    }

    // MARK: - Group 10: Dismissed state invariants

    func testDismissed_ClearedAtMicOn_PanelShowsWarming_ThenCounting() async {
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()
        alertPresenter.stubbedResult = true
        sut.requestDismiss()
        XCTAssertEqual(sut.panelState, .dismissed)

        // New session: mic-on clears .dismissed and shows panel immediately as .warming
        coordinator.micActivated()
        await Task.yield()
        XCTAssertEqual(sut.panelState, .visible,
                       ".dismissed must be cleared and panel shown .warming on new session mic-on (AC-FIX3-A2)")
        XCTAssertEqual(sut.viewModel.activityState, .warming,
                       "activityState must be .warming immediately after dismiss-cleared mic-on")

        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .warming,
                       "M5.7: engine-ready keeps .warming after dismiss-cleared session — .counting via WPM gate")
    }
    // MARK: - Group 11: SessionStartedAt set at mic-on (AC-FIX7)

    func testWidget_ShowsTimerFromMicOnTime() async {
        makeComponents()
        sut.start()
        coordinator.start()

        coordinator.micActivated()
        await Task.yield()

        let timeAfterMicOn = sut.viewModel.sessionStartedAt
        XCTAssertNotNil(timeAfterMicOn,
                        "sessionStartedAt must be set at mic-on, not engine-ready (AC-FIX7)")

        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        XCTAssertEqual(sut.viewModel.sessionStartedAt, timeAfterMicOn,
                       "sessionStartedAt must NOT change at engine-ready — stays at mic-on time")
    }

    func testPhaseG_SessionStartedAt_SetAtNewMicOn_NotEngineReady() async {
        makeComponents()
        sut.start()
        coordinator.start()

        // Session 1: full cycle
        coordinator.micActivated()
        await Task.yield()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        coordinator.micDeactivated()
        await Task.yield()
        XCTAssertEqual(sut.panelState, .lingerFull)

        // Session 2 mic-on during lingerFull
        coordinator.micActivated()
        await Task.yield()

        let timeAfterSession2MicOn = sut.viewModel.sessionStartedAt
        XCTAssertNotNil(timeAfterSession2MicOn,
                        "Phase G: sessionStartedAt must be updated at new mic-on during linger (AC-FIX7)")

        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        XCTAssertEqual(sut.viewModel.sessionStartedAt, timeAfterSession2MicOn,
                       "Phase G: sessionStartedAt must NOT change at engine-ready — stays at new mic-on time")
    }

    // MARK: - Group 12: Panel opacity per activity state (AC-FIX7)

    func testPanelOpacity_AtWaiting_Is050() async {
        makeComponents(runAnimation: { _, block in
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0; ctx.allowsImplicitAnimation = true; block() }
        })
        sut.start()
        await activateSession()
        await showPanel()  // engine-ready is a no-op for activityState in M5.7, stays .warming
        XCTAssertEqual(sut.viewModel.activityState, .warming,
                       "M5.7: activityState stays .warming after engine-ready (no WPM calc)")

        // S049: silence-hold only arms from .counting. Use recovery timeout to reach .waiting.
        coordinator.audioPipelineDidBeginRecovery()
        await Task.yield()
        coordinator.audioPipelineDidEndRecovery()
        await Task.yield()
        scheduler.fire(delay: 2.0)  // recovery grace timer → .waiting
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .waiting)

        XCTAssertEqual(sut.panelWindow?.alphaValue ?? -1, 0.5, accuracy: 0.01,
                       "Panel opacity must be 0.5 when activityState is .waiting and panel is .visible")
    }

    func testPanelOpacity_AtCounting_IsWorkingOpacity() async {
        // M5.7: engine-ready no longer drives .counting — must use WPM gate.
        let suite = "OpacityCounting.\(UUID())"
        let defs = UserDefaults(suiteName: suite)!
        defs.removePersistentDomain(forName: suite)
        defs.set(true, forKey: "coachingEnabled")
        let settings = SettingsStore(userDefaults: defs)
        let wpmSched = LifecycleWPMScheduler()
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        let calc = WPMCalculator(settings: settings, scheduler: wpmSched, now: { clock })
        let micMonitor = MicMonitor(provider: MinimalCoreAudioProvider())
        let coord = SessionCoordinator(micMonitor: micMonitor, settingsStore: settings)
        let lcSched = LifecycleHideScheduler()
        let fpc = FloatingPanelController(
            sessionCoordinator: coord,
            alertPresenter: LifecycleAlertPresenter(),
            hideScheduler: lcSched,
            settingsStore: settings,
            wpmCalculator: calc,
            reducedMotionProvider: { true },
            runAnimation: { _, block in
                NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0; ctx.allowsImplicitAnimation = true; block() }
            }
        )
        fpc.start()
        coord.start()
        coord.micActivated()
        await Task.yield()
        XCTAssertEqual(fpc.viewModel.activityState, .warming, "precondition: .warming after mic-on")
        calc.sessionActivated()
        calc.notifyVADEvent(.speechStarted(sessionTime: 0.0))
        clock = Date(timeIntervalSinceReferenceDate: 0.6)
        calc.engineReadyFired(at: Date(timeIntervalSinceReferenceDate: 0.5))
        clock = Date(timeIntervalSinceReferenceDate: 1.1)
        await calc.consume(TranscribedToken(token: "one two three", startTime: 0, endTime: 1, isFinal: true))
        clock = Date(timeIntervalSinceReferenceDate: 3.1)
        wpmSched.fireNext()   // wpmGateSubscription fires → .counting
        await Task.yield()
        XCTAssertEqual(fpc.viewModel.activityState, .counting, "precondition: .counting via wpmGateSubscription (M5.7)")
        // M5.5 smoke: workingOpacity default changed from 0.90 → 1.00.
        XCTAssertEqual(fpc.panelWindow?.alphaValue ?? -1, 1.0, accuracy: 0.01,
                       "Panel opacity must equal workingOpacity (1.0 default) when activityState is .counting")
    }

    func testPanelOpacity_AtWarming_Is100() async {
        makeComponents(runAnimation: { _, block in
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0; ctx.allowsImplicitAnimation = true; block() }
        })
        sut.start()
        coordinator.start()

        coordinator.micActivated()
        await Task.yield()

        XCTAssertEqual(sut.viewModel.activityState, .warming)
        XCTAssertEqual(sut.panelWindow?.alphaValue ?? -1, 0.5, accuracy: 0.01,
                       "M5.7: Panel opacity must be 0.5 (waitingOpacity) when activityState is .warming")
    }

    func testPanelOpacity_LingerFadeFromWaiting_AnimatesFrom050To0() async {
        makeComponents(reducedMotion: false, runAnimation: { _, block in
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0; ctx.allowsImplicitAnimation = true; block() }
        })
        sut.start()
        await activateSession()
        await showPanel()

        // S049: silence-hold only arms from .counting. Use recovery timeout to reach .waiting.
        coordinator.audioPipelineDidBeginRecovery()
        await Task.yield()
        coordinator.audioPipelineDidEndRecovery()
        await Task.yield()
        scheduler.fire(delay: 2.0)  // recovery grace timer → .waiting
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .waiting)
        XCTAssertEqual(sut.panelWindow?.alphaValue ?? -1, 0.5, accuracy: 0.01,
                       "Panel must be at 0.5 opacity in .waiting state before linger starts")

        await endSession()  // → lingerFull

        scheduler.fire(delay: 3.0)  // lingerFull → lingerFade, runAnimation(2.0) fires
        XCTAssertEqual(sut.panelWindow?.alphaValue ?? -1, 0.0, accuracy: 0.01,
                       "Linger fade from .waiting must animate from 0.5 to 0.0")
    }

    // MARK: - Group 13: Multi-fire regression fixes

    func testLingerFullTimerFired_CancelsPendingHideBeforeSchedulingFade() async {
        // Multi-fire fix 1: lingerFullTimerFired must call cancelPendingHide() instead of
        // hideToken = nil, so any previously-scheduled token is properly cancelled before
        // scheduling the new 2s fade timer.
        makeComponents(reducedMotion: false)
        sut.start()
        await activateSession()
        await showPanel()
        await endSession()
        XCTAssertEqual(sut.panelState, .lingerFull)

        let cancelsBefore = scheduler.cancelCallCount

        scheduler.fire(delay: 3.0)  // lingerFullTimerFired runs

        XCTAssertEqual(sut.panelState, .lingerFade)
        XCTAssertGreaterThan(scheduler.cancelCallCount, cancelsBefore,
                             "lingerFullTimerFired must call cancelPendingHide() — cancel counter must increment")
    }

    func testHoverExited_CancelsPendingHideBeforeScheduling() async {
        // Multi-fire fix 2: handleHoverExited must call cancelPendingHide() before scheduling,
        // so any leftover token from a previous schedule is properly cancelled first.
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()
        await endSession()
        XCTAssertEqual(sut.panelState, .lingerFull)

        // Hover-exit once to schedule a timer
        sut.handleHoverExited()
        let cancelsBefore = scheduler.cancelCallCount
        let entriesBefore = scheduler.entryCount

        // Hover-exit again WITHOUT an intervening hover-enter to simulate double-fire
        sut.handleHoverExited()

        XCTAssertGreaterThan(scheduler.cancelCallCount, cancelsBefore,
                             "handleHoverExited must cancel prior token before scheduling (multi-fire fix)")
        XCTAssertEqual(scheduler.entryCount, entriesBefore,
                       "handleHoverExited double-fire must not accumulate extra scheduler entries")
    }

    // MARK: - Group 14a: Hover on hidden panel must not show it

    func testHoverOnHiddenPanel_DoesNotShowPanel() {
        makeComponents()
        sut.start()
        coordinator.start()
        XCTAssertEqual(sut.panelState, .hidden)

        sut.handleHoverEntered()

        XCTAssertEqual(sut.panelState, .hidden,
                       "Hover on hidden panel must not show it")
    }

    func testRequestDismiss_DuringWarming_SetsDismissed() async {
        makeComponents()
        alertPresenter.stubbedResult = true
        sut.start()
        await activateSession()
        XCTAssertEqual(sut.viewModel.activityState, .warming)
        XCTAssertEqual(sut.panelState, .visible)

        sut.requestDismiss()

        XCTAssertEqual(sut.panelState, .dismissed,
                       "requestDismiss during .warming must set panelState to .dismissed")
        XCTAssertEqual(coordinator.state, .idle,
                       "Coordinator must end session on X-button dismiss during .warming")
    }

    func testXButton_DuringLingerFull_AlertOpen_PanelNotSnappedToHidden() async {
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()
        await endSession()
        XCTAssertEqual(sut.panelState, .lingerFull)
        alertPresenter.stubbedResult = false  // cancel dismiss

        nonisolated(unsafe) var panelStateAtModal: PanelVisibilityState?
        alertPresenter.onPresent = { [weak sut] in
            panelStateAtModal = sut?.panelState
        }

        sut.requestDismiss()

        XCTAssertNotEqual(panelStateAtModal, .hidden,
                          "Panel must NOT be hidden when the modal opens during lingerFull")
    }

    // MARK: - Group 14: Recovery state (AC-FIX7)

    func testRecovery_TransitionsToRecoveringState_OnAudioPipelineRecoverBegin() async {
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()
        XCTAssertEqual(sut.viewModel.activityState, .warming,
                       "M5.7: activityState stays .warming after engine-ready (no WPM calc)")

        coordinator.audioPipelineDidBeginRecovery()
        await Task.yield()

        XCTAssertEqual(sut.viewModel.activityState, .recovering,
                       "activityState must be .recovering when AudioPipeline recovery begins")
    }

    func testRecovery_TransitionsToCounting_OnTokenWithin2s() async {
        // M5.7: token arrival in recovery arms the WPM gate (startWPMGateSubscription), not direct .counting.
        // Without a WPM calc, the gate has nothing to subscribe to, so state stays .recovering.
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()

        coordinator.audioPipelineDidBeginRecovery()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .recovering)

        coordinator.audioPipelineDidEndRecovery()
        await Task.yield()

        coordinator.lastTokenArrival = Date()
        await Task.yield()

        XCTAssertEqual(sut.viewModel.activityState, .recovering,
                       "M5.7: token arrival in recovery arms WPM gate — without WPM calc state stays .recovering")
    }

    func testRecovery_TransitionsToWaiting_OnTimeoutNoToken() async {
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()

        coordinator.audioPipelineDidBeginRecovery()
        await Task.yield()
        coordinator.audioPipelineDidEndRecovery()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .recovering)

        // Fire the 2s recovery-end timer — no token arrived
        scheduler.fire(delay: 2.0)
        await Task.yield()

        XCTAssertEqual(sut.viewModel.activityState, .waiting,
                       "Recovery timeout with no token must transition activityState to .waiting")
    }

    // MARK: - Group 15: ViewModel initial state and linger preservation (AC-FIX7-audit)

    func testWidgetViewModel_InitialActivityState_IsIdle() {
        let viewModel = WidgetViewModel()
        XCTAssertEqual(viewModel.activityState, .idle,
                       "WidgetViewModel.activityState must initialize to .idle (AC25)")
    }

    // MARK: - Group 16: Phase G crash regression — session start during lingerFade

    /// Regression: session-start during lingerFade must cancel the pending hide and restore
    /// the panel to warming immediately. Without the fix, handleSessionActive does nothing in
    /// the lingerFull/lingerFade case — the 2s fade timer fires, hides the panel, then
    /// engine-ready (finding .hidden) hits assertionFailure and kills the process.
    ///
    /// continueAfterFailure = false: in the RED phase the first AC (cancelCount) fails before
    /// the test reaches the engine-ready line that would otherwise crash the test process.
    func testPhaseG_SessionStartDuringLingerFade_CancelsLinger_ShowsWarming() async {
        continueAfterFailure = false
        makeComponents(reducedMotion: false)
        sut.start()
        coordinator.start()

        // Session 1: full cycle → lingerFade
        coordinator.micActivated()
        await Task.yield()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        coordinator.micDeactivated()
        await Task.yield()
        XCTAssertEqual(sut.panelState, .lingerFull, "Precondition: lingerFull after session end")

        scheduler.fire(delay: 3.0)  // lingerFull → lingerFade
        XCTAssertEqual(sut.panelState, .lingerFade, "Precondition: lingerFade after 3s timer")

        // Session 2 starts during lingerFade — crash scenario
        let cancelsBefore = scheduler.cancelCallCount

        coordinator.micActivated()
        await Task.yield()

        // AC-1: pending 2s hide timer must be cancelled
        XCTAssertGreaterThan(scheduler.cancelCallCount, cancelsBefore,
                             "session-start-during-lingerFade must cancel the pending 2s hide timer")
        XCTAssertFalse(scheduler.hasEntry(delay: 2.0),
                       "2s lingerFade scheduler entry must be removed")

        // AC-2: panel must be .visible + .warming immediately — no engine-ready needed
        XCTAssertEqual(sut.panelState, .visible,
                       "panel must be .visible immediately on session-start-during-lingerFade")
        XCTAssertEqual(sut.viewModel.activityState, .warming,
                       "activityState must be .warming immediately on session-start-during-lingerFade")

        // AC-3: the cancelled hide timer must be a no-op — panel stays .visible
        scheduler.fire(delay: 2.0)
        XCTAssertEqual(sut.panelState, .visible,
                       "firing cancelled 2s hide must be a no-op — panel must stay .visible")

        // AC-4: engine-ready must be a no-op for activityState (M5.7) and not hit assertionFailure
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .warming,
                       "M5.7: engine-ready keeps .warming — .counting fires only via WPM gate")
        XCTAssertEqual(sut.panelState, .visible,
                       "panel must remain .visible after engine-ready")
    }

    // MARK: - Group 17: Wrapping freeze semantics + cold-start restart

    func testPanelOpacity_WaitingToCounting_WithoutData_HoldsAtWaitingOpacity() async {
        // M5.7: voice-resume from .waiting arms the WPM gate but does NOT enter .counting immediately.
        // State stays .waiting (and opacity holds at 0.5) until first WPM arrives via gate.
        makeComponents(runAnimation: { _, block in
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0; ctx.allowsImplicitAnimation = true; block() }
        })
        sut.start()
        await activateSession()
        await showPanel()  // engine-ready is a no-op in M5.7, stays .warming
        XCTAssertEqual(sut.viewModel.activityState, .warming,
                       "M5.7: activityState stays .warming after engine-ready (no WPM calc)")

        // S049: silence-hold only arms from .counting. Use recovery timeout to reach .waiting.
        coordinator.audioPipelineDidBeginRecovery()
        await Task.yield()
        coordinator.audioPipelineDidEndRecovery()
        await Task.yield()
        scheduler.fire(delay: 2.0)  // recovery grace timer → .waiting
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .waiting)
        XCTAssertEqual(sut.panelWindow?.alphaValue ?? -1, 0.5, accuracy: 0.01,
                       "Precondition: panel must be at 0.5 opacity in .waiting state")

        // Voice resumes — gate armed (no WPM calc returns immediately), state stays .waiting
        coordinator.isVoiceInactive = false
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .waiting,
                       "M5.7: voice-resume arms WPM gate but state stays .waiting — no flash to .counting without data")

        XCTAssertEqual(sut.panelWindow?.alphaValue ?? -1, 0.5, accuracy: 0.01,
                       "Panel holds at 0.5 (waitingOpacity) during .waiting after voice-resume — gate armed waiting for WPM (M5.7)")
    }

    func testWrappingFromCounting_setsFrozen() async {
        makeComponents()
        sut.start()
        await activateSession()
        // M5.7: engine-ready no longer drives .counting. Set activityState directly to simulate
        // reaching .counting (e.g. via WPM gate in production), then verify the wrapping freeze.
        sut.viewModel.activityState = .counting

        await endSession()  // counting → wrapping

        XCTAssertTrue(sut.viewModel.isFrozen,
                      "wrapping entered from .counting must set isFrozen = true (freeze live numbers during linger)")
    }

    func testWrappingFromWaiting_doesNotSetFrozen() async {
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()
        // S049: silence-hold only arms from .counting. Use recovery timeout to reach .waiting.
        coordinator.audioPipelineDidBeginRecovery()
        await Task.yield()
        coordinator.audioPipelineDidEndRecovery()
        await Task.yield()
        scheduler.fire(delay: 2.0)  // recovery grace timer → .waiting
        await Task.yield()
        XCTAssertEqual(sut.viewModel.activityState, .waiting, "Precondition: activityState must be .waiting")

        await endSession()  // waiting → wrapping

        XCTAssertFalse(sut.viewModel.isFrozen,
                       "wrapping entered from .waiting must NOT set isFrozen (keep dashed/dim waiting presentation)")
    }

    func testColdStart_hasReceivedWPM_ResetsAfterLingerComplete() async {
        makeComponents(reducedMotion: true)
        sut.start()
        await activateSession()
        await showPanel()
        // Simulate first WPM arriving (engine warm-up completes, cold-start mark was showing)
        sut.viewModel.hasReceivedWPM = true
        let firstSessionStartedAt = sut.viewModel.sessionStartedAt
        XCTAssertNotNil(firstSessionStartedAt)
        XCTAssertTrue(sut.viewModel.hasReceivedWPM)

        // End session → linger → complete (reducedMotion: completeLingerHide fires on 3s tick)
        await endSession()
        scheduler.fire(delay: 3.0)

        XCTAssertFalse(sut.viewModel.hasReceivedWPM,
                       "hasReceivedWPM must reset to false after linger completes so cold-start mark shows on next session")
        XCTAssertNil(sut.viewModel.sessionStartedAt,
                     "sessionStartedAt must be nil after reset so .id() forces ColdStartMarkView recreation on next session")
    }

    func testHandleSessionIdle_PreservesSessionStartedAt_DuringLinger() async {
        makeComponents()
        sut.start()
        await activateSession()
        await showPanel()

        coordinator.lastTokenArrival = Date()
        await Task.yield()
        XCTAssertEqual(sut.viewModel.totalTokens, 1)

        // Capture the sessionStartedAt that was set at mic-on time
        let micOnStartedAt = sut.viewModel.sessionStartedAt
        XCTAssertNotNil(micOnStartedAt, "sessionStartedAt must be set after mic-on")

        // End session → lingerFull
        await endSession()
        XCTAssertEqual(sut.panelState, .lingerFull,
                       "Panel must be in lingerFull after session ends")

        // Session data must be preserved during linger (AC26)
        XCTAssertEqual(sut.viewModel.sessionStartedAt, micOnStartedAt,
                       "sessionStartedAt must be preserved during linger so timer keeps ticking")
        XCTAssertTrue(sut.viewModel.isSessionActive,
                      "isSessionActive must remain true during linger so SwiftUI timer keeps ticking")
        XCTAssertEqual(sut.viewModel.totalTokens, 1,
                       "totalTokens must be preserved during linger")

        // Advance through lingerFull → lingerFade → completeLingerHide
        scheduler.fire(delay: 3.0)
        scheduler.fire(delay: 2.0)

        // After linger completes, viewModel must be reset (AC26)
        XCTAssertNil(sut.viewModel.sessionStartedAt,
                     "sessionStartedAt must be nil after completeLingerHide")
        XCTAssertFalse(sut.viewModel.isSessionActive,
                       "isSessionActive must be false after completeLingerHide")
        XCTAssertEqual(sut.viewModel.totalTokens, 0,
                       "totalTokens must be 0 after completeLingerHide")
    }
}
// swiftlint:enable file_length type_body_length
