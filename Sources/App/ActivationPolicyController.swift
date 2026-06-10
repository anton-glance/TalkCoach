import AppKit

@MainActor
final class ActivationPolicyController {
    static let shared = ActivationPolicyController()
    private var registeredWindows: Set<String> = []

    private init() {}

    func registerWindow(_ id: String) {
        registeredWindows.insert(id)
        NSApp.setActivationPolicy(.regular)
    }

    func unregisterWindow(_ id: String) {
        registeredWindows.remove(id)
        if registeredWindows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
