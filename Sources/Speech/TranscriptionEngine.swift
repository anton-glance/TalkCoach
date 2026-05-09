import Foundation
import os

private let logger = Logger.transcription

// MARK: - TranscriptionEngine

/// Routes a session locale to the correct transcriber backend:
/// Apple SpeechTranscriber for supported locales, Parakeet for the rest.
/// If neither supports the locale, throws `TranscriberBackendError.unsupportedLocale`.
final class TranscriptionEngine {
    nonisolated let tokenStream: AsyncStream<TranscribedToken>

    private let locale: Locale
    private let backend: any TranscriberBackend
    private let continuation: AsyncStream<TranscribedToken>.Continuation
    private var relayTask: Task<Void, Never>?

    var backendName: String { String(describing: type(of: backend)) }

    // async because SpeechTranscriber.supportedLocales is an async property;
    // throws because an unsupported locale is a programming error caught at session start.
    init(
        locale: Locale,
        audioBufferProvider: any AudioBufferProvider,
        appleBackendFactory: any AppleBackendFactory,
        parakeetBackendFactory: any ParakeetBackendFactory,
        supportedLocalesProvider: any SupportedLocalesProvider
    ) async throws {
        self.locale = locale

        var cont: AsyncStream<TranscribedToken>.Continuation!
        self.tokenStream = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { cont = $0 }
        self.continuation = cont

        let appleLocales = await supportedLocalesProvider.supportedLocales()
        let isAppleSupported = appleLocales.contains { localeMatches($0, locale) }

        if isAppleSupported {
            logger.info("TranscriptionEngine: routing \(locale.identifier) → Apple backend")
            self.backend = appleBackendFactory.make(audioBufferProvider: audioBufferProvider)
        } else if parakeetBackendFactory.supports(locale: locale) {
            logger.info("TranscriptionEngine: routing \(locale.identifier) → Parakeet backend")
            self.backend = parakeetBackendFactory.make(audioBufferProvider: audioBufferProvider)
        } else {
            logger.error("TranscriptionEngine: no backend supports \(locale.identifier)")
            throw TranscriberBackendError.unsupportedLocale(locale)
        }
    }

    func start() async throws {
        try await backend.start(locale: locale)

        let upstream = backend.tokenStream
        let cont = continuation
        relayTask = Task {
            for await token in upstream {
                cont.yield(token)
            }
            cont.finish()
        }
    }

    func stop() async {
        relayTask?.cancel()
        await backend.stop()
        continuation.finish()
    }
}
