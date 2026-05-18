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
    private let now: () -> Date
    private let reducedMotionProvider: () -> Bool
    let viewModel = WidgetViewModel()

    private var panel: CoachingPanel?
    private var stateSubscription: AnyCancellable?
    private var tokenArrivalSubscription: AnyCancellable?
    private var captureStateSubscription: AnyCancellable?
    private var engineReadySubscription: AnyCancellable?
    private var tokenSilenceSubscription: AnyCancellable?
    private var hideToken: HideSchedulerToken?
    private var dragDebounceToken: HideSchedulerToken?
    private var countingTimeoutToken: HideSchedulerToken?
    private var moveObserver: (any NSObjectProtocol)?
    private var isProgrammaticMove = false
    private var isStarted = false
    private var lastTokenObservedAtNs: UInt64 = 0
    private var lingerStartedAt: Date?

    var isShowingPanel: Bool { panel?.isVisible ?? false }
    var currentPanelFrame: NSRect? { panel?.frame }
    var panelWindow: NSPanel? { panel }

    init(
        sessionCoordinator: SessionCoordinator,
        alertPresenter: AlertPresenter = SystemAlertPresenter(),
        hideScheduler: HideScheduler = DispatchHideScheduler(),
        screenProvider: ScreenProvider = SystemScreenProvider(),
        settingsStore: SettingsStore = SettingsStore(),
        now: @escaping () -> Date = { Date() },
        reducedMotionProvider: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.alertPresenter = alertPresenter
        self.hideScheduler = hideScheduler
        self.screenProvider = screenProvider
        self.settingsStore = settingsStore
        self.now = now
        self.reducedMotionProvider = reducedMotionProvider
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

        tokenSilenceSubscription = sessionCoordinator.$isInTokenSilence
            .dropFirst()
            .sink { [weak self] isSilent in
                guard let self, isSilent else { return }
                self.viewModel.activityState = .waiting
                Logger.floatingPanel.info("activity state: waiting (token-silence)")
            }

        captureStateSubscription = sessionCoordinator.$captureActivityState
            .sink { [weak self] newState in
                guard let self else { return }
                self.handleCaptureActivityStateChange(newState)
            }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        Logger.floatingPanel.info("FloatingPanelController stopping")

        stateSubscription = nil
        tokenArrivalSubscription = nil
        captureStateSubscription = nil
        engineReadySubscription = nil
        tokenSilenceSubscription = nil
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
            moveObserver = nil
        }
        cancelPendingDragDebounce()
        cancelPendingHide()
        cancelCountingTimeout()
        lingerStartedAt = nil
        hidePanel(reason: "lifecycle-stop")
    }

    func requestDismiss() {
        guard panelState == .visible || panelState == .lingerFull || panelState == .lingerFade else { return }
        let sourceState = panelState
        Logger.floatingPanel.info("Dismiss requested")

        let confirmed = alertPresenter.presentDismissConfirmation()
        if confirmed {
            cancelPendingHide()
            lingerStartedAt = nil
            panelState = .dismissed
            hidePanel(reason: "dismissed")
            if sourceState == .visible {
                sessionCoordinator.requestFinalize()
            }
            Logger.floatingPanel.info("Dismiss confirmed — panel hidden")
        } else {
            Logger.floatingPanel.info("Dismiss canceled — panel stays in \(String(describing: self.panelState))")
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
        // Linger timers survive into Phase G — cancel pending hide only outside linger.
        switch panelState {
        case .hidden, .visible, .dismissed:
            cancelPendingHide()
        case .lingerFull, .lingerFade:
            break
        }

        if panelState == .dismissed {
            panelState = .hidden
            Logger.floatingPanel.info("New session — clearing prior dismiss state for \(ctx.id)")
        }

        viewModel.isSessionActive = true
        Logger.floatingPanel.info("Session active \(ctx.id) — widget will appear on engine-ready")
    }

    private func handleSessionIdle() {
        cancelCountingTimeout()
        viewModel.isSessionActive = false
        viewModel.sessionStartedAt = nil

        switch panelState {
        case .visible:
            cancelPendingHide()
            startLingerFull()
            Logger.floatingPanel.info("Session ended while visible — starting lingerFull")

        case .dismissed:
            break  // Stays dismissed until new session clears it in handleSessionActive

        case .lingerFull, .lingerFade, .hidden:
            break
        }
    }

    private func handleEngineReady() {
        cancelCountingTimeout()
        switch panelState {
        case .hidden:
            guard case .active = sessionCoordinator.state else { return }
            viewModel.sessionStartedAt = now()
            viewModel.isSessionActive = true
            viewModel.activityState = .waiting
            panelState = .visible
            showPanel()
            armCountingTimeout()
            Logger.floatingPanel.info("Engine ready — panel shown (.visible)")
        case .visible:
            armCountingTimeout()
        case .lingerFull:
            // Phase G: in-place content swap — cancel linger, reset content, stay showing
            cancelPendingHide()
            lingerStartedAt = nil
            resetViewModel()
            viewModel.sessionStartedAt = now()
            viewModel.isSessionActive = true
            viewModel.activityState = .waiting
            panelState = .visible
            armCountingTimeout()
            Logger.floatingPanel.info("Phase G: engine-ready during lingerFull — in-place content swap → .visible")
        case .lingerFade:
            // Phase G: cancel fade, snap alpha, reset content, stay showing
            cancelPendingHide()
            panel?.alphaValue = 1.0
            lingerStartedAt = nil
            resetViewModel()
            viewModel.sessionStartedAt = now()
            viewModel.isSessionActive = true
            viewModel.activityState = .waiting
            panelState = .visible
            armCountingTimeout()
            Logger.floatingPanel.info("Phase G: engine-ready during lingerFade — fade cancelled, in-place content swap → .visible")
        case .dismissed:
            break
        }
    }

    private func handleTokenArrival() {
        let t2Ns = DispatchTime.now().uptimeNanoseconds
        switch panelState {
        case .visible:
            viewModel.totalTokens += 1
            viewModel.activityState = .counting
            cancelCountingTimeout()
            armCountingTimeout()
            let t3Ns = DispatchTime.now().uptimeNanoseconds
            let t1Ns = lastTokenObservedAtNs
            let sinkLatencyMs = Double(t2Ns - t1Ns) / 1_000_000.0
            let totalLatencyMs = Double(t3Ns - t1Ns) / 1_000_000.0
            Logger.floatingPanel.info("widget-token-timing: sink→handler=\(sinkLatencyMs)ms total=\(totalLatencyMs)ms")
        case .lingerFull, .lingerFade:
            viewModel.totalTokens += 1
            viewModel.activityState = .counting
            cancelCountingTimeout()
            armCountingTimeout()
        case .hidden, .dismissed:
            break
        }
    }

    // MARK: - Linger sequence

    private func startLingerFull() {
        panelState = .lingerFull
        lingerStartedAt = now()
        hideToken = hideScheduler.schedule(delay: 3.0) { [weak self] in
            guard let self else { return }
            self.lingerFullTimerFired()
        }
        Logger.floatingPanel.info("LingerFull started — 3s countdown")
    }

    private func lingerFullTimerFired() {
        guard panelState == .lingerFull else { return }
        hideToken = nil
        if reducedMotionProvider() {
            completeLingerHide()
        } else {
            panelState = .lingerFade
            hideToken = hideScheduler.schedule(delay: 2.0) { [weak self] in
                guard let self else { return }
                self.completeLingerHide()
            }
            Logger.floatingPanel.info("LingerFull expired — starting lingerFade (2s)")
        }
    }

    private func completeLingerHide() {
        hideToken = nil
        lingerStartedAt = nil
        hidePanel(reason: "linger-complete")
        resetViewModel()
        Logger.floatingPanel.info("Linger complete — panel hidden, viewModel reset")
    }

    private func resetViewModel() {
        viewModel.totalTokens = 0
        viewModel.activityState = .waiting
    }

    private func armCountingTimeout() {
        countingTimeoutToken = hideScheduler.schedule(delay: 1.5) { [weak self] in
            guard let self, self.viewModel.activityState == .counting else { return }
            self.viewModel.activityState = .waiting
            Logger.floatingPanel.info("activity state: waiting (counting-timeout)")
            self.countingTimeoutToken = nil
        }
        Logger.floatingPanel.info("activity state: counting (token #\(self.viewModel.totalTokens))")
    }

    // MARK: - Panel Management

    private static let panelSize: CGFloat = 144
    private static let defaultInset: CGFloat = 16

    private func showPanel() {
        let thePanel = panel ?? createPanel()
        panel = thePanel

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
            rootView: PlaceholderWidgetView(viewModel: viewModel) { [weak self] in
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

    // MARK: - Capture Activity State

    private func handleCaptureActivityStateChange(_ newState: CaptureActivityState) {
        // CaptureActivityState has only .waiting; the probe/resume cycle was removed in M3.7.3-fix5.
        switch newState {
        case .waiting:
            break
        }
    }

    // MARK: - Hover tracking

    func handleHoverEntered() {
        switch panelState {
        case .lingerFull:
            cancelPendingHide()
        case .lingerFade:
            cancelPendingHide()
            panelState = .lingerFull
            lingerStartedAt = nil
        default:
            break
        }
    }

    func handleHoverExited() {
        guard panelState == .lingerFull else { return }
        let start = lingerStartedAt ?? now()
        let elapsed = now().timeIntervalSince(start)
        let remaining = max(0.5, 3.0 - elapsed)
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

    private func cancelCountingTimeout() {
        if let token = countingTimeoutToken {
            hideScheduler.cancel(token)
            countingTimeoutToken = nil
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
