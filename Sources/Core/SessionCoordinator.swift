import Combine
import OSLog

enum SessionState: Equatable {
    case idle
    case active(SessionContext)
}

struct SessionContext: Equatable {
    let id: UUID
    let startedAt: Date
}

struct EndedSession: Equatable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
}

@MainActor
final class SessionCoordinator: ObservableObject {
    @Published private(set) var state: SessionState = .idle
    private(set) var isRunning: Bool = false

    private let micMonitor: MicMonitor
    private let settingsStore: SettingsStore
    private var endedSessionHandlers: [@MainActor (EndedSession) -> Void] = []
    private var coachingEnabledCancellable: AnyCancellable?

    var currentSession: SessionContext? {
        if case .active(let ctx) = state { return ctx } else { return nil }
    }

    init(micMonitor: MicMonitor, settingsStore: SettingsStore) {
        self.micMonitor = micMonitor
        self.settingsStore = settingsStore
    }

    func start() {}

    func stop() {}

    func onSessionEnded(_ handler: @escaping @MainActor (EndedSession) -> Void) {
        endedSessionHandlers.append(handler)
    }
}

extension SessionCoordinator: MicMonitorDelegate {
    func micActivated() {}
    func micDeactivated() {}
}
