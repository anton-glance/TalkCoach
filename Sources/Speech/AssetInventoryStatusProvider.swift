import Foundation
import Speech

// MARK: - InstalledLocalesProvider (Convention-6 seam)

nonisolated protocol InstalledLocalesProvider: Sendable {
    func installedLocales() async -> [Locale]
}

nonisolated struct SystemInstalledLocalesProvider: InstalledLocalesProvider {
    func installedLocales() async -> [Locale] { await SpeechTranscriber.installedLocales }
}

// MARK: - AssetInventoryStatusProvider

nonisolated protocol AssetInventoryStatusProvider: Sendable {
    /// Returns true if the model for the given transcriber is already installed on disk.
    func isInstalled(transcriber: SpeechTranscriber) async throws -> Bool
}

// MARK: - SystemAssetInventoryStatusProvider

nonisolated struct SystemAssetInventoryStatusProvider: AssetInventoryStatusProvider {
    private let installedLocalesProvider: any InstalledLocalesProvider

    init(installedLocalesProvider: any InstalledLocalesProvider = SystemInstalledLocalesProvider()) {
        self.installedLocalesProvider = installedLocalesProvider
    }

    func isInstalled(transcriber: SpeechTranscriber) async throws -> Bool {
        // installedLocales is the empirical source of truth: a locale present here means
        // SpeechAnalyzer.start() will succeed for it on this machine (verified Session 026
        // diagnostic). The previously-used AssetInventory.assetInstallationRequest signal
        // returns non-nil even when the model is fully usable — it's the API for triggering
        // download flows (M3.6 territory), not a session-start gate. See journal entry
        // Session 026 for the full diagnostic findings and Spike #6 for the prior
        // SpeechTranscriber.supportedLocale(equivalentTo:) trap of similar shape.
        let locale = Mirror(reflecting: transcriber).children
            .first(where: { $0.label == "locale" })?.value as? Locale
        guard let locale else {
            return try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) == nil
        }
        let installed = await installedLocalesProvider.installedLocales()
        return installed.contains { $0.identifier == locale.identifier }
    }
}
