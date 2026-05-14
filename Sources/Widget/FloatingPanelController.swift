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
    case fadingOut
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
    let viewModel = WidgetViewModel()

    private var panel: CoachingPanel?
    private var stateSubscription: AnyCancellable?
    private var tokenArrivalSubscription: AnyCancellable?
    private var hideToken: HideSchedulerToken?
    private var dragDebounceToken: HideSchedulerToken?
    private var moveObserver: (any NSObjectProtocol)?
    private var isProgrammaticMove = false
    private var isStarted = false
    private var lastTokenObservedAtNs: UInt64 = 0

    var isShowingPanel: Bool { panel?.isVisible ?? false }
    var currentPanelFrame: NSRect? { panel?.frame }
    var panelWindow: NSPanel? { panel }

    init(
        sessionCoordinator: SessionCoordinator,
        alertPresenter: AlertPresenter = SystemAlertPresenter(),
        hideScheduler: HideScheduler = DispatchHideScheduler(),
        screenProvider: ScreenProvider = SystemScreenProvider(),
        settingsStore: SettingsStore = SettingsStore()
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.alertPresenter = alertPresenter
        self.hideScheduler = hideScheduler
        self.screenProvider = screenProvider
        self.settingsStore = settingsStore
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

        // Token-silence decoupling: hide is driven by token arrival gaps, not session-end.
        // Each token resets the hide timer. Absence of tokens for widgetHideDelaySeconds hides the panel.
        tokenArrivalSubscription = sessionCoordinator.$lastTokenArrival
            .sink { [weak self] arrival in
                let t1Ns = DispatchTime.now().uptimeNanoseconds
                guard let self, arrival != nil else { return }
                self.lastTokenObservedAtNs = t1Ns
                self.handleTokenArrival()
            }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        Logger.floatingPanel.info("FloatingPanelController stopping")

        stateSubscription = nil
        tokenArrivalSubscription = nil
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
            moveObserver = nil
        }
        cancelPendingDragDebounce()
        cancelPendingHide()
        hidePanel(reason: "lifecycle-stop")
    }

    func requestDismiss() {
        guard panelState == .visible else { return }
        Logger.floatingPanel.info("Dismiss requested")

        let confirmed = alertPresenter.presentDismissConfirmation()
        if confirmed {
            panelState = .dismissed
            hidePanel(reason: "dismissed")
            sessionCoordinator.requestFinalize()
            Logger.floatingPanel.info("Dismiss confirmed — panel hidden, session finalized")
        } else {
            Logger.floatingPanel.info("Dismiss canceled — panel stays visible")
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
        cancelPendingHide()

        switch panelState {
        case .hidden:
            viewModel.sessionStartedAt = ctx.startedAt
            viewModel.isSessionActive = true
            panelState = .visible
            showPanel()
            Logger.floatingPanel.info("Panel shown for session \(ctx.id)")

        case .fadingOut:
            viewModel.sessionStartedAt = ctx.startedAt
            viewModel.isSessionActive = true
            panelState = .visible
            Logger.floatingPanel.info("Panel reactivated (cancel fade) for session \(ctx.id)")

        case .visible, .dismissed:
            break
        }
    }

    private func handleSessionIdle() {
        viewModel.isSessionActive = false
        viewModel.sessionStartedAt = nil

        switch panelState {
        case .visible, .fadingOut:
            // M3.7.3: session-end hides immediately. The fade timer is driven by token-silence
            // (handleTokenArrival), which fires before the session ends in normal usage.
            // A hard session-end (coaching disabled, sleep, shutdown) hides immediately.
            cancelPendingHide()
            hidePanel(reason: "session-ended")
            Logger.floatingPanel.info("Session ended — panel hidden immediately (M3.7.3)")

        case .dismissed:
            panelState = .hidden
            Logger.floatingPanel.info("Session ended while dismissed — hidden")

        case .hidden:
            break
        }
    }

    private func handleTokenArrival() {
        let t2Ns = DispatchTime.now().uptimeNanoseconds
        // A token arrived — reset the token-silence hide timer, and re-show if hidden.
        cancelPendingHide()
        switch panelState {
        case .hidden, .fadingOut:
            // Re-show only when a session is actually active; ignore stale token signals while idle.
            guard case .active(let ctx) = sessionCoordinator.state else { return }
            viewModel.sessionStartedAt = ctx.startedAt
            viewModel.isSessionActive = true
            panelState = .visible
            showPanel()
            let t3Ns = DispatchTime.now().uptimeNanoseconds
            let t1Ns = lastTokenObservedAtNs
            let sinkLatencyMs = Double(t2Ns - t1Ns) / 1_000_000.0
            let showLatencyMs = Double(t3Ns - t2Ns) / 1_000_000.0
            let totalLatencyMs = Double(t3Ns - t1Ns) / 1_000_000.0
            Logger.floatingPanel.info("widget-reshow-timing: trigger=reshow sink→handler=\(sinkLatencyMs)ms handler→visible=\(showLatencyMs)ms total=\(totalLatencyMs)ms")
            armHideTimer()
        case .visible:
            armHideTimer()
            let t3Ns = DispatchTime.now().uptimeNanoseconds
            let t1Ns = lastTokenObservedAtNs
            let sinkLatencyMs = Double(t2Ns - t1Ns) / 1_000_000.0
            let totalLatencyMs = Double(t3Ns - t1Ns) / 1_000_000.0
            Logger.floatingPanel.info("widget-reshow-timing: trigger=reschedule sink→handler=\(sinkLatencyMs)ms total=\(totalLatencyMs)ms")
        case .dismissed:
            return
        }
    }

    private func armHideTimer() {
        let delay = settingsStore.widgetHideDelaySeconds
        hideToken = hideScheduler.schedule(delay: delay) { [weak self] in
            guard let self, self.panelState == .visible else { return }
            self.panelState = .fadingOut
            self.hidePanel(reason: "token-silence-fade")
            self.panelState = .hidden
            Logger.floatingPanel.info("Token-silence timer fired — panel hidden after \(delay)s of silence")
        }
        Logger.floatingPanel.debug("Token arrived — hide timer rearmed for \(delay)s")
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
        let hostingView = NSHostingView(
            rootView: PlaceholderWidgetView(viewModel: viewModel) { [weak self] in
                self?.requestDismiss()
            }
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelSize, height: Self.panelSize)
        coachingPanel.contentView = hostingView
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

    // MARK: - Hide Timer

    private func cancelPendingHide() {
        if let token = hideToken {
            hideScheduler.cancel(token)
            hideToken = nil
        }
    }
}
