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
final class FloatingPanelController {
    private(set) var panelState: PanelVisibilityState = .hidden

    private let sessionCoordinator: SessionCoordinator
    private let alertPresenter: AlertPresenter
    private let hideScheduler: HideScheduler
    private let screenProvider: ScreenProvider
    private let settingsStore: SettingsStore
    private let viewModel = WidgetViewModel()

    private var panel: CoachingPanel?
    private var stateSubscription: AnyCancellable?
    private var hideToken: HideSchedulerToken?
    private var isStarted = false

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
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        Logger.floatingPanel.info("FloatingPanelController stopping")

        stateSubscription = nil
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
            Logger.floatingPanel.info("Dismiss confirmed — panel hidden")
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
        case .visible:
            panelState = .fadingOut
            scheduleHide()
            Logger.floatingPanel.info("Session ended — fading out (5s)")

        case .dismissed:
            panelState = .hidden
            Logger.floatingPanel.info("Session ended while dismissed — hidden")

        case .fadingOut, .hidden:
            break
        }
    }

    // MARK: - Panel Management

    private static let panelSize: CGFloat = 144
    private static let defaultInset: CGFloat = 16

    private func showPanel() {
        let thePanel = panel ?? createPanel()
        panel = thePanel

        let frame = frameForShow()
        thePanel.setFrame(frame, display: false)
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
        coachingPanel.onDragEnd = { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.handlePanelDragEnd(panelFrame: panel.frame)
        }
        coachingPanel.contentView = hostingView
        return coachingPanel
    }

    // MARK: - Position Logic

    private func frameForShow() -> NSRect {
        let targetScreen = screenProvider.mainScreen()
            ?? screenProvider.allScreens().first
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

    // MARK: - Hide Timer

    private func scheduleHide() {
        hideToken = hideScheduler.schedule(delay: 5.0) { [weak self] in
            guard let self, self.panelState == .fadingOut else { return }
            self.hidePanel(reason: "mic-off-fade")
            self.panelState = .hidden
        }
    }

    private func cancelPendingHide() {
        if let token = hideToken {
            hideScheduler.cancel(token)
            hideToken = nil
        }
    }
}
