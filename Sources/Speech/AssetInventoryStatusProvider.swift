import Foundation
import Speech

// MARK: - AssetInventoryStatusProvider

nonisolated protocol AssetInventoryStatusProvider: Sendable {
    /// Returns true if the model for the given transcriber is already installed on disk.
    func isInstalled(transcriber: SpeechTranscriber) async throws -> Bool
}

// MARK: - SystemAssetInventoryStatusProvider

nonisolated struct SystemAssetInventoryStatusProvider: AssetInventoryStatusProvider {
    func isInstalled(transcriber: SpeechTranscriber) async throws -> Bool {
        let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        return request == nil
    }
}
