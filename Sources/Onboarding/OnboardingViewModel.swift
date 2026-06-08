import AVFoundation
import Combine
import Foundation

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published var currentStep: Int = 1
    @Published var micGranted: Bool = false
    @Published var primaryLocaleID: String? = nil
    @Published var secondaryLocaleID: String? = nil
    @Published var revokeHintVisible: Bool = false

    var canContinueStep2: Bool { false }  // stub: always false — tests 6,7 fail

    private let settingsStore: SettingsStore
    let statusProvider: PermissionStatusProvider
    var onComplete: (() -> Void)?

    init(
        settingsStore: SettingsStore,
        statusProvider: PermissionStatusProvider = SystemPermissionStatusProvider(),
        onComplete: @escaping () -> Void = {}
    ) {
        self.settingsStore = settingsStore
        self.statusProvider = statusProvider
        self.onComplete = onComplete
    }

    func advance() { }  // stub: noop — test 2 fails

    func requestMicPermission() async { }  // stub: noop — tests 8,9 fail

    func setPrimaryLocale(_ id: String?) { }  // stub: noop — tests 10,11 fail

    func setSecondaryLocale(_ id: String?) { }  // stub: noop — test 11 fails

    func complete() { }  // stub: noop — tests 12,13,14 fail
}
