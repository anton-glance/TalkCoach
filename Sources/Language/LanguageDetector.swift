import Foundation
import os

private let logger = Logger.lang

// MARK: - Error type

nonisolated enum LanguageDetectorError: Error, Sendable {
    case noLocalesDeclared
    case detectionFailed(underlying: Error)
}

// MARK: - LanguageDetector

/// Decides which of the user's declared locales to use for the current session.
/// Uses a script-aware hybrid of three detection strategies validated by Spike #2
/// (Session 010). Convention-6 protocol injection for all external dependencies:
/// `PartialTranscriptProvider` (wired by M3.7), `WhisperLIDProvider` (wired by M3.6),
/// `AudioBufferProvider` (wraps `AudioPipeline` from M3.1).
actor LanguageDetector {
    nonisolated let localeChange: AsyncStream<Locale>

    private let declaredLocales: [Locale]
    private let strategy: any LanguageDetectionStrategy
    private let continuation: AsyncStream<Locale>.Continuation
    private var isStarted = false
    private var isStopped = false
    private var detectionTask: Task<Void, Never>?
    private var storedLocale: Locale?

    init(
        declaredLocales: [Locale],
        partialTranscriptProvider: any PartialTranscriptProvider,
        whisperLIDProvider: any WhisperLIDProvider,
        audioBufferProvider: any AudioBufferProvider
    ) {
        self.declaredLocales = declaredLocales

        var cont: AsyncStream<Locale>.Continuation!
        self.localeChange = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        self.continuation = cont

        if declaredLocales.count <= 1 {
            self.strategy = SingleLocaleStrategy(
                initialLocale: declaredLocales.first ?? Locale(identifier: "en_US")
            )
        } else {
            let s1 = dominantScript(for: declaredLocales[0])
            let s2 = dominantScript(for: declaredLocales[1])

            if s1 == s2 {
                self.strategy = SameScriptStrategy(
                    declaredLocales: declaredLocales,
                    provider: partialTranscriptProvider
                )
            } else if s1.isCJK || s2.isCJK {
                self.strategy = WhisperLIDStrategy(
                    declaredLocales: declaredLocales,
                    whisperProvider: whisperLIDProvider,
                    audioProvider: audioBufferProvider
                )
            } else {
                self.strategy = WordCountStrategy(
                    declaredLocales: declaredLocales,
                    provider: partialTranscriptProvider
                )
            }
        }
    }

    func start() async throws -> Locale {
        guard !isStarted, !isStopped else { return storedLocale ?? strategy.initialLocale }
        isStarted = true

        if strategy.isBlocking {
            let detected = try await strategy.runDetection(continuation: continuation)
            let locale = detected ?? strategy.initialLocale
            storedLocale = locale
            return locale
        } else {
            let s = strategy
            let c = continuation
            detectionTask = Task { [s, c] in
                _ = try? await s.runDetection(continuation: c)
            }
            let locale = strategy.initialLocale
            storedLocale = locale
            return locale
        }
    }

    func stop() {
        guard isStarted else { return }
        detectionTask?.cancel()
        continuation.finish()
        isStarted = false
        isStopped = true
    }
}
