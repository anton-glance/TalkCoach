import Foundation

// MARK: - ParakeetBackendFactory

nonisolated protocol ParakeetBackendFactory: Sendable {
    func supports(locale: Locale) -> Bool
    func make(audioBufferProvider: any AudioBufferProvider) -> any TranscriberBackend
}

// MARK: - StubParakeetTranscriberBackend

nonisolated final class StubParakeetTranscriberBackend: TranscriberBackend, @unchecked Sendable {
    let tokenStream: AsyncStream<TranscribedToken> = AsyncStream { $0.finish() }

    func start(locale: Locale) async throws {
        throw TranscriberBackendError.modelUnavailable
    }

    func stop() async {}
}

// MARK: - StubParakeetBackendFactory

nonisolated struct StubParakeetBackendFactory: ParakeetBackendFactory {
    let supportedLocaleIdentifiers: [String]

    func supports(locale: Locale) -> Bool {
        supportedLocaleIdentifiers.contains(locale.identifier)
    }

    func make(audioBufferProvider: any AudioBufferProvider) -> any TranscriberBackend {
        StubParakeetTranscriberBackend()
    }
}
