import AppKit
import Combine
import OSLog
import SwiftUI

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

    private func showPanel() {
        let thePanel = panel ?? createPanel()
        panel = thePanel

        let frame = Self.defaultPanelFrame()
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
        let frame = Self.defaultPanelFrame()
        let coachingPanel = CoachingPanel(contentRect: frame)
        let hostingView = NSHostingView(
            rootView: PlaceholderWidgetView(viewModel: viewModel) { [weak self] in
                self?.requestDismiss()
            }
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 144, height: 144)
        coachingPanel.contentView = hostingView
        return coachingPanel
    }

    static func defaultPanelFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let xOrigin = visibleFrame.maxX - 144 - 16
        let yOrigin = visibleFrame.maxY - 144 - 16
        return NSRect(x: xOrigin, y: yOrigin, width: 144, height: 144)
    }

    func handlePanelDragEnd(panelFrame: NSRect) {
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
