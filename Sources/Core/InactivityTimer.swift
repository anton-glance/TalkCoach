import Foundation

protocol InactivityTimer: AnyObject {
    func schedule(after timeout: TimeInterval, action: @escaping @MainActor () -> Void)
    func cancel()
}

// Stub — no-op until green commit wires in DispatchWorkItem logic.
final class DispatchInactivityTimer: InactivityTimer {
    func schedule(after timeout: TimeInterval, action: @escaping @MainActor () -> Void) {}
    func cancel() {}
}
