import AVFoundation
import Combine
import Foundation
import OSLog

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published var currentStep: Int = 1
    @Published var micGranted: Bool = false
    @Published var micDenied: Bool = false
    @Published var primaryLocaleID: String?
    @Published var secondaryLocaleID: String?
    @Published var revokeHintVisible: Bool = false

    let settingsStore: SettingsStore
    let statusProvider: PermissionStatusProvider
    var onComplete: (() -> Void)?

    var canContinueStep2: Bool {
        guard micGranted, let primary = primaryLocaleID else { return false }
        if let secondary = secondaryLocaleID, !secondary.isEmpty {
            return secondary != primary
        }
        return true
    }

    init(
        settingsStore: SettingsStore,
        statusProvider: PermissionStatusProvider = SystemPermissionStatusProvider(),
        onComplete: @escaping () -> Void = {}
    ) {
        self.settingsStore = settingsStore
        self.statusProvider = statusProvider
        self.onComplete = onComplete
        let micStatus = statusProvider.micAuthorizationStatus()
        micGranted = micStatus == .authorized
        micDenied = micStatus == .denied
        primaryLocaleID = settingsStore.declaredLocales.first
        secondaryLocaleID = settingsStore.declaredLocales.count > 1
            ? settingsStore.declaredLocales[1]
            : nil
        if primaryLocaleID == nil, settingsStore.declaredLocales.isEmpty {
            let langCode = Locale.current.language.languageCode?.identifier ?? "en"
            let matched = LocaleRegistry.parakeetSupportedLocales.first { $0.identifier == langCode }
            primaryLocaleID = matched?.identifier ?? "en"
            syncLocalesToStore()
        }
    }

    func advance() {
        guard currentStep < 5 else { return }
        currentStep += 1
    }

    func requestMicPermission() async {
        let granted = await statusProvider.requestMicAccess()
        micGranted = granted
        micDenied = !granted
    }

    func setPrimaryLocale(_ id: String?) {
        primaryLocaleID = id
        syncLocalesToStore()
    }

    func setSecondaryLocale(_ id: String?) {
        secondaryLocaleID = (id?.isEmpty == false) ? id : nil
        syncLocalesToStore()
    }

    func complete() {
        settingsStore.hasCompletedOnboarding = true
        settingsStore.hasCompletedSetup = true
        onComplete?()
    }

    private func syncLocalesToStore() {
        var locales: [String] = []
        if let primary = primaryLocaleID { locales.append(primary) }
        if let secondary = secondaryLocaleID { locales.append(secondary) }
        settingsStore.declaredLocales = locales
    }
}
