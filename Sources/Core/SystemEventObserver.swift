import AppKit
import OSLog

/// Observes system-level events (sleep, shutdown/logout) that require active sessions
/// to be finalized immediately to avoid resource leaks or corrupted state.
protocol SystemEventObserving: Sendable {
    func start(
        onSleep: @escaping @MainActor () -> Void,
        onShutdown: @escaping @MainActor () -> Void
    )
    func stop()
}

// MARK: - Production Implementation

final class SystemEventObserver: SystemEventObserving, @unchecked Sendable {
    // nonisolated(unsafe): mutation only on @MainActor (start/stop); deinit has exclusive ownership.
    nonisolated(unsafe) private var sleepObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var shutdownObserver: (any NSObjectProtocol)?

    func start(
        onSleep: @escaping @MainActor () -> Void,
        onShutdown: @escaping @MainActor () -> Void
    ) {
        let nc = NSWorkspace.shared.notificationCenter

        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self != nil else { return }
            MainActor.assumeIsolated { onSleep() }
        }

        shutdownObserver = nc.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self != nil else { return }
            MainActor.assumeIsolated { onShutdown() }
        }

        Logger.session.info("SystemEventObserver: started (sleep + shutdown listeners registered)")
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        if let obs = sleepObserver { nc.removeObserver(obs); sleepObserver = nil }
        if let obs = shutdownObserver { nc.removeObserver(obs); shutdownObserver = nil }
        Logger.session.info("SystemEventObserver: stopped")
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        if let obs = sleepObserver { nc.removeObserver(obs) }
        if let obs = shutdownObserver { nc.removeObserver(obs) }
    }
}
