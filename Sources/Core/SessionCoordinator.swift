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

/// Orchestrates session lifecycle: receives `MicMonitor` activation events,
/// gates session creation on `coachingEnabled`, and exposes session state
/// for SwiftUI consumers and one-shot end-of-session subscribers.
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

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Logger.session.info("SessionCoordinator started")

        micMonitor.delegate = self
        micMonitor.start()

        coachingEnabledCancellable = settingsStore.$coachingEnabled
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                if !newValue, case .active = self.state {
                    Logger.session.info("Coaching disabled mid-session — ending active session")
                    self.endCurrentSession()
                }
            }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        Logger.session.info("SessionCoordinator stopping")

        coachingEnabledCancellable = nil

        if case .active = state {
            endCurrentSession()
        }

        micMonitor.stop()
        micMonitor.delegate = nil
    }

    func onSessionEnded(_ handler: @escaping @MainActor (EndedSession) -> Void) {
        endedSessionHandlers.append(handler)
    }

    private func endCurrentSession() {
        guard case .active(let ctx) = state else { return }
        let ended = EndedSession(id: ctx.id, startedAt: ctx.startedAt, endedAt: Date())
        state = .idle
        Logger.session.info("Session ended: \(ended.id) duration \(ended.endedAt.timeIntervalSince(ended.startedAt), format: .fixed(precision: 1))s")
        for handler in endedSessionHandlers {
            handler(ended)
        }
    }
}

extension SessionCoordinator: MicMonitorDelegate {
    func micActivated() {
        guard settingsStore.coachingEnabled else {
            Logger.session.info("Mic activated, coaching disabled — ignoring")
            return
        }
        guard case .idle = state else {
            Logger.session.info("Mic activated but session already active — ignoring")
            return
        }
        let ctx = SessionContext(id: UUID(), startedAt: Date())
        state = .active(ctx)
        Logger.session.info("Session started: \(ctx.id) at \(ctx.startedAt)")
    }

    func micDeactivated() {
        guard case .active = state else { return }
        endCurrentSession()
    }
}
