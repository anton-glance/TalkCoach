import AppKit
import Combine
import OSLog

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

    var isShowingPanel: Bool { false }

    init(
        sessionCoordinator: SessionCoordinator,
        alertPresenter: AlertPresenter = SystemAlertPresenter(),
        hideScheduler: HideScheduler = DispatchHideScheduler()
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.alertPresenter = alertPresenter
        self.hideScheduler = hideScheduler
    }

    func start() {}
    func stop() {}
    func requestDismiss() {}
}
