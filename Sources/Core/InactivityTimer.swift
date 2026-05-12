import Foundation

protocol InactivityTimer: AnyObject {
    func schedule(after timeout: TimeInterval, action: @escaping @MainActor () -> Void)
    func cancel()
}

// Mirrors DispatchHideScheduler (M2.5): DispatchWorkItem.cancel() is synchronous and
// guaranteed — if cancelled before execution the block never runs, preventing post-cancel fires.
final class DispatchInactivityTimer: InactivityTimer {
    private var workItem: DispatchWorkItem?

    func schedule(after timeout: TimeInterval, action: @escaping @MainActor () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem { Task { @MainActor in action() } }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
