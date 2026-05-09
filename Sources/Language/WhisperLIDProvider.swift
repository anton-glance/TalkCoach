import Foundation

nonisolated enum WhisperLIDProviderError: Error, Sendable {
    case modelUnavailable
    case inferenceFailed(underlying: Error)
}

nonisolated protocol WhisperLIDProvider: Sendable {
    func detectLanguage(
        from buffers: [CapturedAudioBuffer],
        constrainedTo locales: [Locale]
    ) async throws -> Locale
}

nonisolated struct StubWhisperLIDProvider: WhisperLIDProvider {
    func detectLanguage(
        from buffers: [CapturedAudioBuffer],
        constrainedTo locales: [Locale]
    ) async throws -> Locale {
        throw WhisperLIDProviderError.modelUnavailable
    }
}
