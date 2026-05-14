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
        let center = NSWorkspace.shared.notificationCenter

        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self != nil else { return }
            MainActor.assumeIsolated { onSleep() }
        }

        shutdownObserver = center.addObserver(
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
        let center = NSWorkspace.shared.notificationCenter
        if let obs = sleepObserver { center.removeObserver(obs); sleepObserver = nil }
        if let obs = shutdownObserver { center.removeObserver(obs); shutdownObserver = nil }
        Logger.session.info("SystemEventObserver: stopped")
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        if let obs = sleepObserver { center.removeObserver(obs) }
        if let obs = shutdownObserver { center.removeObserver(obs) }
    }
}
