// swiftlint:disable file_length
import AppKit
import Combine
import OSLog
import SwiftUI

private extension NSRect {
    var area: CGFloat { width * height }
}

enum PanelVisibilityState: Equatable {
    case hidden
    case visible
    case dismissed
    case lingerFull
    case lingerFade
}

@MainActor
// swiftlint:disable:next type_body_length
final class FloatingPanelController {
    private(set) var panelState: PanelVisibilityState = .hidden

    private let sessionCoordinator: SessionCoordinator
    private let alertPresenter: AlertPresenter
    private let hideScheduler: HideScheduler
    private let screenProvider: ScreenProvider
    private let settingsStore: SettingsStore
    private let wpmCalculator: WPMCalculator?
    private let monologueDetector: MonologueDetector?
    private let now: () -> Date
    private let reducedMotionProvider: () -> Bool
    private let runAnimation: (TimeInterval, @escaping () -> Void) -> Void
    let viewModel: WidgetViewModel

    private var panel: CoachingPanel?
    private var stateSubscription: AnyCancellable?
    private var tokenArrivalSubscription: AnyCancellable?
    private var engineReadySubscription: AnyCancellable?
    private var voiceInactiveSubscription: AnyCancellable?
    private var recoverySubscription: AnyCancellable?
    private var hideToken: HideSchedulerToken?
    private var widgetRefreshToken: HideSchedulerToken?
    private var wpmFirstValueSubscription: AnyCancellable?
    private var dragDebounceToken: HideSchedulerToken?
    private var recoveryEndToken: HideSchedulerToken?
    private var silenceHoldToken: HideSchedulerToken?
    private var moveObserver: (any NSObjectProtocol)?

    private var isProgrammaticMove = false
    private var isStarted = false
    private var lastTokenObservedAtNs: UInt64 = 0
    private var lingerStartedAt: Date?

    private let isoFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    var isShowingPanel: Bool { panel?.isVisible ?? false }
    var currentPanelFrame: NSRect? { panel?.frame }
    var panelWindow: NSPanel? { panel }

    init(
        sessionCoordinator: SessionCoordinator,
        alertPresenter: AlertPresenter = SystemAlertPresenter(),
        hideScheduler: HideScheduler = DispatchHideScheduler(),
        screenProvider: ScreenProvider = SystemScreenProvider(),
        settingsStore: SettingsStore = SettingsStore(),
        wpmCalculator: WPMCalculator? = nil,
        monologueDetector: MonologueDetector? = nil,
        now: @escaping () -> Date = { Date() },
        reducedMotionProvider: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        },
        runAnimation: @escaping (TimeInterval, @escaping () -> Void) -> Void = { duration, block in
            NSAnimationContext.runAnimationGroup({
                $0.duration = duration
                $0.allowsImplicitAnimation = true
                block()
            })
        }
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.alertPresenter = alertPresenter
        self.hideScheduler = hideScheduler
        self.screenProvider = screenProvider
        self.settingsStore = settingsStore
        self.wpmCalculator = wpmCalculator
        self.monologueDetector = monologueDetector
        self.now = now
        self.reducedMotionProvider = reducedMotionProvider
        self.runAnimation = runAnimation
        self.viewModel = WidgetViewModel(settings: settingsStore)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        Logger.floatingPanel.info("FloatingPanelController started")

        stateSubscription = sessionCoordinator.$state
            .sink { [weak self] newState in
                guard let self else { return }
                self.handleStateChange(newState)
            }

        tokenArrivalSubscription = sessionCoordinator.$lastTokenArrival
            .sink { [weak self] arrival in
                let t1Ns = DispatchTime.now().uptimeNanoseconds
                guard let self, arrival != nil else { return }
                self.lastTokenObservedAtNs = t1Ns
                self.handleTokenArrival()
            }

        engineReadySubscription = sessionCoordinator.$lastEngineReadyAt
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.handleEngineReady()
            }

        voiceInactiveSubscription = sessionCoordinator.$isVoiceInactive
            .dropFirst()
            .sink { [weak self] isInactive in
                guard let self else { return }
                if isInactive {
                    self.startSilenceHoldTimer()
                } else {
                    self.cancelSilenceHoldTimer()
                    if self.panelState == .visible, self.viewModel.activityState == .waiting {
                        self.setActivityState(.counting, reason: "vad-active")
                    }
                }
            }

        recoverySubscription = sessionCoordinator.$isRecovering
            .dropFirst()
            .sink { [weak self] isRecovering in
                guard let self else { return }
                if isRecovering {
                    self.handleRecoveryBegan()
                } else {
                    self.handleRecoveryEnded()
                }
            }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        Logger.floatingPanel.info("FloatingPanelController stopping")

        stateSubscription = nil
        tokenArrivalSubscription = nil
        engineReadySubscription = nil
        voiceInactiveSubscription = nil
        recoverySubscription = nil
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
            moveObserver = nil
        }
        stopWidgetRefreshTimer()
        cancelPendingDragDebounce()
        cancelPendingHide()
        cancelRecoveryEndTimer()
        cancelSilenceHoldTimer()
        lingerStartedAt = nil
        hidePanel(reason: "lifecycle-stop")
    }

    func requestDismiss() {
        guard panelState == .visible || panelState == .lingerFull || panelState == .lingerFade else { return }
        let sourceState = panelState
        Logger.floatingPanel.info("Dismiss requested")

        let confirmed: Bool
        switch panelState {
        case .lingerFade:
            Logger.floatingPanel.info("X-button during lingerFade — snapping alpha before modal")
            cancelPendingHide()
            panel?.alphaValue = 1.0
            confirmed = alertPresenter.presentDismissConfirmation()
        case .lingerFull:
            Logger.floatingPanel.info("X-button during lingerFull — pausing countdown before modal")
            cancelPendingHide()
            confirmed = alertPresenter.presentDismissConfirmation()
        default:
            confirmed = alertPresenter.presentDismissConfirmation()
        }

        if confirmed {
            cancelPendingHide()  // no-op for linger (already cancelled); needed for .visible
            lingerStartedAt = nil
            panelState = .dismissed
            hidePanel(reason: "dismissed")
            resetViewModel()
            if sourceState == .visible {
                sessionCoordinator.requestFinalize()
            }
            Logger.floatingPanel.info("Dismiss confirmed — panel hidden")
        } else {
            switch panelState {
            case .lingerFade, .lingerFull:
                panelState = .lingerFull
                lingerStartedAt = now()
                hideToken = hideScheduler.schedule(delay: settingsStore.lingerFullSeconds) { [weak self] in
                    guard let self else { return }
                    self.lingerFullTimerFired()
                }
                Logger.floatingPanel.info(
                    "Dismiss canceled from \(String(describing: sourceState)) — restarting lingerFull"
                )
            case .visible, .hidden, .dismissed:
                Logger.floatingPanel.info(
                    "Dismiss canceled — panel stays in \(String(describing: self.panelState))"
                )
            }
        }
    }

    // MARK: - State Machine

    private func handleStateChange(_ newState: SessionState) {
        switch newState {
        case .active(let ctx):
            handleSessionActive(ctx)
        case .idle:
            handleSessionIdle()
        }
    }

    private func handleSessionActive(_ ctx: SessionContext) {
        switch panelState {
        case .hidden, .visible, .dismissed:
            cancelPendingHide()
        case .lingerFull, .lingerFade:
            break  // linger cancel handled below in the per-state block
        }

        if panelState == .dismissed {
            panelState = .hidden
            Logger.floatingPanel.info("New session — clearing prior dismiss state for \(ctx.id)")
        }

        viewModel.isSessionActive = true
        viewModel.sessionStartedAt = ctx.startedAt  // always set to mic-on time

        switch panelState {
        case .hidden:
            panelState = .visible
            showPanel()
            setActivityState(.warming, reason: "session-active")
            Logger.floatingPanel.info("Session active \(ctx.id) — panel shown warming")
        case .visible:
            setActivityState(.warming, reason: "session-active")  // rapid restart within same visible state
        case .lingerFull, .lingerFade:
            // Phase G: cancel the pending hide immediately so the fade timer cannot fire and
            // hide the panel before engine-ready arrives (~3s), which would leave panelState
            // .hidden and trigger assertionFailure in handleEngineReady.
            cancelPendingHide()
            panel?.alphaValue = 1.0
            lingerStartedAt = nil
            resetViewModel()
            viewModel.isSessionActive = true
            viewModel.sessionStartedAt = ctx.startedAt
            panelState = .visible
            applyPanelOpacity(animated: false)
            setActivityState(.warming, reason: "session-active")
            Logger.floatingPanel.info("Phase G: session-active during linger [\(ctx.id)] — linger cancelled → warming")
        case .dismissed:
            break
        }
    }

    private func handleSessionIdle() {
        cancelRecoveryEndTimer()
        cancelSilenceHoldTimer()

        switch panelState {
        case .visible:
            cancelPendingHide()
            setActivityState(.wrapping, reason: "session-idle")
            startLingerFull()
            Logger.floatingPanel.info("Session ended while visible — starting lingerFull")

        case .dismissed:
            break  // Stays dismissed until new session clears it in handleSessionActive

        case .lingerFull, .lingerFade, .hidden:
            break
        }
    }

    private func handleEngineReady() {
        guard case .active(let ctx) = sessionCoordinator.state else { return }
        switch panelState {
        case .hidden:
            // Unreachable: handleSessionActive always shows the panel (warming) before engine-ready fires.
            assertionFailure("engine-ready while hidden — handleSessionActive should have shown warming panel first")
        case .visible:
            // warming → counting
            setActivityState(.counting, reason: "engine-ready")
        case .lingerFull:
            // Phase G: in-place content swap — cancel linger, reset content, stay showing
            cancelPendingHide()
            lingerStartedAt = nil
            resetViewModel()
            viewModel.isSessionActive = true
            viewModel.sessionStartedAt = ctx.startedAt
            panelState = .visible
            applyPanelOpacity(animated: false)
            setActivityState(.counting, reason: "engine-ready-phase-g")
            Logger.floatingPanel.info("Phase G: engine-ready during lingerFull — in-place content swap → .counting")
        case .lingerFade:
            // Phase G: cancel fade, snap alpha, reset content, stay showing
            cancelPendingHide()
            panel?.alphaValue = 1.0
            lingerStartedAt = nil
            resetViewModel()
            viewModel.isSessionActive = true
            viewModel.sessionStartedAt = ctx.startedAt
            panelState = .visible
            applyPanelOpacity(animated: false)
            setActivityState(.counting, reason: "engine-ready-phase-g")
            Logger.floatingPanel.info("Phase G: engine-ready during lingerFade — fade cancelled → .counting")
        case .dismissed:
            break
        }
    }

    private func handleTokenArrival() {
        let t2Ns = DispatchTime.now().uptimeNanoseconds
        switch panelState {
        case .visible:
            viewModel.totalTokens += 1
            cancelRecoveryEndTimer()
            // Gate is the sole authority for counting↔waiting. Tokens exit .warming
            // but must not override .waiting set by the gate's hold timer.
            if viewModel.activityState != .waiting {
                setActivityState(.counting, reason: "token")
            }
            let t3Ns = DispatchTime.now().uptimeNanoseconds
            let t1Ns = lastTokenObservedAtNs
            let sinkLatencyMs = Double(t2Ns - t1Ns) / 1_000_000.0
            let totalLatencyMs = Double(t3Ns - t1Ns) / 1_000_000.0
            Logger.floatingPanel.info("widget-token-timing: sink→handler=\(sinkLatencyMs)ms total=\(totalLatencyMs)ms")
        case .lingerFull, .lingerFade:
            viewModel.totalTokens += 1
            cancelRecoveryEndTimer()
            setActivityState(.counting, reason: "token")
        case .hidden, .dismissed:
            break
        }
    }

    // MARK: - Linger sequence

    private func startLingerFull() {
        panelState = .lingerFull
        lingerStartedAt = now()
        hideToken = hideScheduler.schedule(delay: settingsStore.lingerFullSeconds) { [weak self] in
            guard let self else { return }
            self.lingerFullTimerFired()
        }
        Logger.floatingPanel.info("LingerFull started — \(self.settingsStore.lingerFullSeconds, format: .fixed(precision: 1))s countdown")
    }

    private func lingerFullTimerFired() {
        guard panelState == .lingerFull else { return }
        cancelPendingHide()  // multi-fire fix: cancel any existing token before scheduling fade
        if reducedMotionProvider() {
            completeLingerHide()
        } else {
            panelState = .lingerFade
            runAnimation(settingsStore.lingerFadeSeconds) { [weak self] in
                self?.panel?.animator().alphaValue = 0.0
            }
            hideToken = hideScheduler.schedule(delay: settingsStore.lingerFadeSeconds) { [weak self] in
                guard let self else { return }
                self.completeLingerHide()
            }
            Logger.floatingPanel.info("LingerFull expired — starting lingerFade (\(self.settingsStore.lingerFadeSeconds, format: .fixed(precision: 1))s)")
        }
    }

    private func completeLingerHide() {
        hideToken = nil
        lingerStartedAt = nil
        hidePanel(reason: "linger-complete")
        // Reset alpha so the next session's showPanel() starts at full opacity,
        // not at the 0.0 the fade animation left it at.
        panel?.alphaValue = 1.0
        resetViewModel()
        setActivityState(.idle, reason: "linger-complete")
        Logger.floatingPanel.info("Linger complete — panel hidden, viewModel reset")
    }

    private func resetViewModel() {
        stopWidgetRefreshTimer()
        viewModel.totalTokens = 0
        viewModel.sessionStartedAt = nil
        viewModel.isSessionActive = false
        viewModel.currentWPMVoiced = nil
        viewModel.monologueLevel = 0
        viewModel.streakSeconds = 0
    }

    // MARK: - Panel Management

    private static let panelSize: CGFloat = 144
    private static let defaultInset: CGFloat = 16

    private func showPanel() {
        let thePanel = panel ?? createPanel()
        panel = thePanel
        thePanel.alphaValue = 1.0  // defensive: always start at full opacity

        let frame = frameForShow()
        isProgrammaticMove = true
        thePanel.setFrame(frame, display: false)
        isProgrammaticMove = false
        thePanel.orderFrontRegardless()
    }

    private func hidePanel(reason: String) {
        panel?.orderOut(nil)
        if panelState != .dismissed {
            panelState = .hidden
        }
        Logger.floatingPanel.info("Panel removed: \(reason)")
    }

    private func createPanel() -> CoachingPanel {
        let frame = frameForShow()
        let coachingPanel = CoachingPanel(contentRect: frame)
        let trackingView = TrackingContentView()
        trackingView.frame = NSRect(x: 0, y: 0, width: Self.panelSize, height: Self.panelSize)
        trackingView.onHoverEntered = { [weak self] in self?.handleHoverEntered() }
        trackingView.onHoverExited = { [weak self] in self?.handleHoverExited() }
        let hostingView = NSHostingView(
            rootView: WidgetView(viewModel: viewModel) { [weak self] in
                self?.requestDismiss()
            }
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelSize, height: Self.panelSize)
        trackingView.addSubview(hostingView)
        coachingPanel.contentView = trackingView
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: coachingPanel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isProgrammaticMove else { return }
                self.debounceDragSave()
            }
        }
        return coachingPanel
    }

    // MARK: - Position Logic

    private func frameForShow() -> NSRect {
        let allScreens = screenProvider.allScreens()
        let targetScreen: ScreenDescription?
        if let lastUsedName = settingsStore.lastUsedDisplay(),
           let match = allScreens.first(where: { $0.localizedName == lastUsedName }) {
            targetScreen = match
            Logger.floatingPanel.info("Using last-used display \(lastUsedName)")
        } else {
            if settingsStore.lastUsedDisplay() != nil {
                Logger.floatingPanel.info("Last-used display disconnected, falling back to NSScreen.main")
            }
            targetScreen = screenProvider.mainScreen() ?? allScreens.first
        }
        guard let targetScreen else {
            return Self.fallbackFrame()
        }
        let screenName = targetScreen.localizedName

        if let saved = settingsStore.position(for: screenName) {
            let absolute = CGPoint(
                x: targetScreen.frame.origin.x + saved.x,
                y: targetScreen.frame.origin.y + saved.y
            )
            let clamped = Self.clamp(absolute, within: targetScreen.visibleFrame)
            if clamped != absolute {
                Logger.floatingPanel.info("Clamped saved position for \(screenName)")
            } else {
                Logger.floatingPanel.info("Restored saved position for \(screenName)")
            }
            return NSRect(origin: clamped, size: CGSize(width: Self.panelSize, height: Self.panelSize))
        }

        Logger.floatingPanel.info("Using default position for \(screenName)")
        return Self.defaultFrame(for: targetScreen)
    }

    func handlePanelDragEnd(panelFrame: NSRect) {
        let allScreens = screenProvider.allScreens()
        guard let destScreen = Self.screenWithMostOverlap(for: panelFrame, in: allScreens)
                ?? screenProvider.mainScreen() else { return }

        let relative = CGPoint(
            x: panelFrame.origin.x - destScreen.frame.origin.x,
            y: panelFrame.origin.y - destScreen.frame.origin.y
        )
        settingsStore.setPosition(relative, for: destScreen.localizedName)
        settingsStore.setLastUsedDisplay(destScreen.localizedName)
        Logger.floatingPanel.info(
            "Saved position (\(relative.x), \(relative.y)) for \(destScreen.localizedName)"
        )
    }

    private static func defaultFrame(for screen: ScreenDescription) -> NSRect {
        let x = screen.visibleFrame.maxX - panelSize - defaultInset
        let y = screen.visibleFrame.maxY - panelSize - defaultInset
        return NSRect(x: x, y: y, width: panelSize, height: panelSize)
    }

    private static func fallbackFrame() -> NSRect {
        let fallback = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = fallback.maxX - panelSize - defaultInset
        let y = fallback.maxY - panelSize - defaultInset
        return NSRect(x: x, y: y, width: panelSize, height: panelSize)
    }

    private static func clamp(_ origin: CGPoint, within visibleFrame: NSRect) -> CGPoint {
        let x = max(visibleFrame.minX, min(origin.x, visibleFrame.maxX - panelSize))
        let y = max(visibleFrame.minY, min(origin.y, visibleFrame.maxY - panelSize))
        return CGPoint(x: x, y: y)
    }

    private static func screenWithMostOverlap(
        for panelFrame: NSRect, in screens: [ScreenDescription]
    ) -> ScreenDescription? {
        screens.max { lhs, rhs in
            let lhsArea = panelFrame.intersection(lhs.frame).area
            let rhsArea = panelFrame.intersection(rhs.frame).area
            return lhsArea < rhsArea
        }
    }

    // MARK: - Drag Debounce

    private func debounceDragSave() {
        if let token = dragDebounceToken {
            hideScheduler.cancel(token)
        }
        dragDebounceToken = hideScheduler.schedule(delay: 0.3) { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.handlePanelDragEnd(panelFrame: panel.frame)
        }
    }

    private func cancelPendingDragDebounce() {
        if let token = dragDebounceToken {
            hideScheduler.cancel(token)
            dragDebounceToken = nil
        }
    }

    // MARK: - Hover tracking

    func handleHoverEntered() {
        switch panelState {
        case .lingerFull:
            cancelPendingHide()
        case .lingerFade:
            cancelPendingHide()
            panel?.alphaValue = 1.0
            panelState = .lingerFull
            lingerStartedAt = nil
        default:
            break
        }
    }

    func handleHoverExited() {
        guard panelState == .lingerFull else { return }
        cancelPendingHide()  // multi-fire fix: cancel prior token before scheduling
        let remaining: TimeInterval
        if let start = lingerStartedAt {
            let elapsed = now().timeIntervalSince(start)
            remaining = max(0.5, settingsStore.lingerFullSeconds - elapsed)
        } else {
            // lingerStartedAt is nil — entered lingerFull from lingerFade via hover.
            // Restart the full countdown.
            lingerStartedAt = now()
            remaining = settingsStore.lingerFullSeconds
        }
        hideToken = hideScheduler.schedule(delay: remaining) { [weak self] in
            guard let self else { return }
            self.lingerFullTimerFired()
        }
    }

    // MARK: - Hide Timer

    private func cancelPendingHide() {
        if let token = hideToken {
            hideScheduler.cancel(token)
            hideToken = nil
        }
    }

    // MARK: - Silence Hold Timer

    private func startSilenceHoldTimer() {
        cancelSilenceHoldTimer()
        silenceHoldToken = hideScheduler.schedule(delay: settingsStore.wpmPauseThreshold) { [weak self] in
            guard let self, self.panelState == .visible else { return }
            self.silenceHoldToken = nil
            self.wpmCalculator?.enterWaiting()
            self.monologueDetector?.enterWaiting()
            self.setActivityState(.waiting, reason: "silence-2s")
        }
    }

    private func cancelSilenceHoldTimer() {
        if let token = silenceHoldToken {
            hideScheduler.cancel(token)
            silenceHoldToken = nil
        }
    }

    // MARK: - State Transition Logger

    private func setActivityState(_ state: WidgetActivityState, reason: String) {
        let prev = viewModel.activityState
        viewModel.activityState = state
        let timestamp = isoFormatter.string(from: now())
        Logger.floatingPanel.info("widget-state: \(timestamp, privacy: .public) \(String(describing: prev), privacy: .public)→\(String(describing: state), privacy: .public) reason=\(reason, privacy: .public)")
        // Start 1s refresh timer on every transition INTO .counting; stop it on every exit FROM .counting.
        if state == .counting && prev != .counting {
            snapshotNow()
            startWidgetRefreshTimer()
        } else if state != .counting && prev == .counting {
            snapshotNow()
            stopWidgetRefreshTimer()
        }
        applyPanelOpacity(animated: true)
    }

    // MARK: - Widget Refresh Timer

    private func snapshotNow() {
        viewModel.currentWPMVoiced = wpmCalculator?.wpmVoiced
        viewModel.streakSeconds    = monologueDetector?.streakSeconds ?? 0
        viewModel.monologueLevel   = monologueDetector?.monologueLevel ?? 0
    }

    private func startWidgetRefreshTimer() {
        stopWidgetRefreshTimer()
        widgetRefreshToken = hideScheduler.schedule(delay: 1.0) { [weak self] in
            self?.onWidgetRefreshFired()
        }
        startWPMFirstValueSubscription()
    }

    private func stopWidgetRefreshTimer() {
        if let token = widgetRefreshToken {
            hideScheduler.cancel(token)
            widgetRefreshToken = nil
        }
        wpmFirstValueSubscription = nil
    }

    // Subscribe to the WPM calculator's published value so the first non-nil reading
    // lands in the viewModel immediately — without waiting up to 1s for the display timer.
    // Also re-phases the 1s timer from the moment data appears, keeping updates coherent.
    // Uses the publisher value directly because @Published fires on willSet; the property
    // itself still holds the old value when the sink runs.
    private func startWPMFirstValueSubscription() {
        guard let calc = wpmCalculator else { return }
        wpmFirstValueSubscription = calc.$wpmVoiced
            .compactMap { $0 }
            .sink { [weak self] newWPM in
                guard let self else { return }
                self.viewModel.currentWPMVoiced = newWPM
                self.viewModel.streakSeconds    = self.monologueDetector?.streakSeconds ?? 0
                self.viewModel.monologueLevel   = self.monologueDetector?.monologueLevel ?? 0
                if let token = self.widgetRefreshToken {
                    self.hideScheduler.cancel(token)
                }
                self.widgetRefreshToken = self.hideScheduler.schedule(delay: 1.0) { [weak self] in
                    self?.onWidgetRefreshFired()
                }
            }
    }

    private func onWidgetRefreshFired() {
        widgetRefreshToken = nil
        snapshotNow()
        startWidgetRefreshTimer()
    }

    // MARK: - Panel Opacity

    private func applyPanelOpacity(animated: Bool) {
        guard panelState == .visible || panelState == .lingerFull || panelState == .lingerFade else { return }
        let targetAlpha: CGFloat?
        switch viewModel.activityState {
        case .waiting: targetAlpha = settingsStore.waitingOpacity
        case .warming, .counting, .recovering: targetAlpha = 1.0
        case .idle, .wrapping, .dismissed: targetAlpha = nil
        }
        guard let alpha = targetAlpha else { return }
        if animated {
            runAnimation(0.3) { [weak self] in
                self?.panel?.animator().alphaValue = alpha
            }
        } else {
            panel?.alphaValue = alpha
        }
    }

    // MARK: - Recovery

    private func handleRecoveryBegan() {
        guard panelState == .visible || panelState == .lingerFull else { return }
        setActivityState(.recovering, reason: "pipeline-recovery-began")
    }

    private func handleRecoveryEnded() {
        cancelRecoveryEndTimer()
        recoveryEndToken = hideScheduler.schedule(delay: settingsStore.recoveryGraceSeconds) { [weak self] in
            guard let self else { return }
            self.handleRecoveryTimeout()
        }
        Logger.floatingPanel.info("Recovery ended — \(self.settingsStore.recoveryGraceSeconds, format: .fixed(precision: 1))s window for token before fallback to waiting")
    }

    private func handleRecoveryTimeout() {
        recoveryEndToken = nil
        guard viewModel.activityState == .recovering else { return }
        setActivityState(.waiting, reason: "recovery-timeout")
    }

    private func cancelRecoveryEndTimer() {
        if let token = recoveryEndToken {
            hideScheduler.cancel(token)
            recoveryEndToken = nil
        }
    }
}

// MARK: - TrackingContentView

final class TrackingContentView: NSView {
    var onHoverEntered: (() -> Void)?
    var onHoverExited: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHoverEntered?() }
    override func mouseExited(with event: NSEvent) { onHoverExited?() }
}
