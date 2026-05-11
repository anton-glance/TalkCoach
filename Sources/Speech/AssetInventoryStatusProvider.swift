import Foundation
import Speech

// MARK: - InstalledLocalesProvider (Convention-6 seam)

// InstalledLocalesProvider is kept as a Convention-6 seam: it lets
// SystemAssetInventoryStatusProvider be unit-tested without real OS state.
// FakeAssetInventoryStatusProvider covers AppleTranscriberBackend at the layer
// above; this seam covers SystemAssetInventoryStatusProvider at the layer below.
nonisolated protocol InstalledLocalesProvider: Sendable {
    func installedLocales() async -> [Locale]
}

nonisolated struct SystemInstalledLocalesProvider: InstalledLocalesProvider {
    func installedLocales() async -> [Locale] { await SpeechTranscriber.installedLocales }
}

// MARK: - AssetInventoryStatusProvider

nonisolated protocol AssetInventoryStatusProvider: Sendable {
    /// Returns true if the speech model for `locale` is installed on this machine.
    func isInstalled(locale: Locale) async throws -> Bool
}

// MARK: - SystemAssetInventoryStatusProvider

nonisolated struct SystemAssetInventoryStatusProvider: AssetInventoryStatusProvider {
    private let installedLocalesProvider: any InstalledLocalesProvider

    init(installedLocalesProvider: any InstalledLocalesProvider = SystemInstalledLocalesProvider()) {
        self.installedLocalesProvider = installedLocalesProvider
    }

    func isInstalled(locale: Locale) async throws -> Bool {
        // SpeechTranscriber.installedLocales is the empirical source of truth: a locale present
        // here means SpeechAnalyzer.start() will succeed (verified Session 026 diagnostic).
        // AssetInventory.assetInstallationRequest returns non-nil even for fully-usable models
        // — it is the API for triggering download flows (M3.6), not a session-start gate.
        let installed = await installedLocalesProvider.installedLocales()
        return installed.contains { $0.identifier == locale.identifier }
    }
}
