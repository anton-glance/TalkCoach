import Foundation

// MARK: - AppleBackendFactory

nonisolated protocol AppleBackendFactory: Sendable {
    func make(audioBufferProvider: any AudioBufferProvider) -> any TranscriberBackend
}

// MARK: - SystemAppleBackendFactory

nonisolated struct SystemAppleBackendFactory: AppleBackendFactory {
    let localesProvider: any SupportedLocalesProvider

    init(localesProvider: any SupportedLocalesProvider = SystemSupportedLocalesProvider()) {
        self.localesProvider = localesProvider
    }

    func make(audioBufferProvider: any AudioBufferProvider) -> any TranscriberBackend {
        AppleTranscriberBackend(
            audioBufferProvider: audioBufferProvider,
            localesProvider: localesProvider
        )
    }
}
