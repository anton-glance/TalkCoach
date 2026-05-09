import Foundation

// MARK: - ParakeetBackendFactory

nonisolated protocol ParakeetBackendFactory: Sendable {
    func supports(locale: Locale) -> Bool
    func make(audioBufferProvider: any AudioBufferProvider) -> any TranscriberBackend
}

// MARK: - PlaceholderParakeetTranscriberBackend

// Temporary placeholder until M3.5b implements the real ParakeetTranscriberBackend.
// Always throws .modelUnavailable; production code routes here only for locales
// Parakeet claims to support (none in this phase).
nonisolated final class PlaceholderParakeetTranscriberBackend: TranscriberBackend, @unchecked Sendable {
    let tokenStream: AsyncStream<TranscribedToken> = AsyncStream { $0.finish() }

    func start(locale: Locale) async throws {
        throw TranscriberBackendError.modelUnavailable
    }

    func stop() async {}
}

// MARK: - PlaceholderParakeetBackendFactory

// Temporary placeholder until M3.5b. Reports no supported locales in this phase.
nonisolated struct PlaceholderParakeetBackendFactory: ParakeetBackendFactory {
    let supportedLocaleIdentifiers: [String]

    func supports(locale: Locale) -> Bool {
        supportedLocaleIdentifiers.contains(locale.identifier)
    }

    func make(audioBufferProvider: any AudioBufferProvider) -> any TranscriberBackend {
        PlaceholderParakeetTranscriberBackend()
    }
}
