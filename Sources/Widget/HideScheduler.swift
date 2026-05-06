import Foundation

protocol HideScheduler: Sendable {
    @MainActor func schedule(
        delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> HideSchedulerToken

    @MainActor func cancel(_ token: HideSchedulerToken)
}

final class HideSchedulerToken: Equatable, Sendable {
    nonisolated static func == (lhs: HideSchedulerToken, rhs: HideSchedulerToken) -> Bool {
        lhs === rhs
    }
}

struct DispatchHideScheduler: HideScheduler {
    @MainActor func schedule(
        delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> HideSchedulerToken {
        let token = HideSchedulerToken()
        let item = DispatchWorkItem { [weak token] in
            guard let token else { return }
            TokenStorage.shared.remove(for: token)
            action()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        TokenStorage.shared.store(item, for: token)
        return token
    }

    @MainActor func cancel(_ token: HideSchedulerToken) {
        TokenStorage.shared.cancel(for: token)
    }
}

@MainActor
private final class TokenStorage {
    static let shared = TokenStorage()
    private var items: [ObjectIdentifier: DispatchWorkItem] = [:]

    func store(_ item: DispatchWorkItem, for token: HideSchedulerToken) {
        items[ObjectIdentifier(token)] = item
    }

    func remove(for token: HideSchedulerToken) {
        items[ObjectIdentifier(token)] = nil
    }

    func cancel(for token: HideSchedulerToken) {
        let key = ObjectIdentifier(token)
        items[key]?.cancel()
        items[key] = nil
    }
}
