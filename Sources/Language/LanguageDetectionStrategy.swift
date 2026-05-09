import Foundation
import NaturalLanguage
import os

private let logger = Logger.lang

nonisolated protocol LanguageDetectionStrategy: Sendable {
    var initialLocale: Locale { get }
    var isBlocking: Bool { get }
    func runDetection(continuation: AsyncStream<Locale>.Continuation) async throws -> Locale?
}

// MARK: - SingleLocaleStrategy (N=1)

nonisolated struct SingleLocaleStrategy: LanguageDetectionStrategy {
    let initialLocale: Locale
    let isBlocking = false

    func runDetection(continuation: AsyncStream<Locale>.Continuation) async throws -> Locale? {
        continuation.finish()
        return nil
    }
}

// MARK: - SameScriptStrategy (Strategy 1)

nonisolated struct SameScriptStrategy: LanguageDetectionStrategy {
    let declaredLocales: [Locale]
    let provider: any PartialTranscriptProvider

    var initialLocale: Locale { declaredLocales[0] }
    let isBlocking = false

    func runDetection(continuation: AsyncStream<Locale>.Continuation) async throws -> Locale? {
        continuation.finish()
        return nil
    }
}

// MARK: - WordCountStrategy (Strategy 2)

nonisolated struct WordCountStrategy: LanguageDetectionStrategy {
    // Spike #2 validated threshold: wrong-locale transcription produces 0–6 words
    // vs correct-locale 14–42 words. t=13 achieves 100% accuracy on EN+RU (16/16).
    static let wordCountThreshold = 13

    let declaredLocales: [Locale]
    let provider: any PartialTranscriptProvider

    var initialLocale: Locale { declaredLocales[0] }
    let isBlocking = false

    func runDetection(continuation: AsyncStream<Locale>.Continuation) async throws -> Locale? {
        continuation.finish()
        return nil
    }
}

// MARK: - WhisperLIDStrategy (Strategy 3)

nonisolated struct WhisperLIDStrategy: LanguageDetectionStrategy {
    let declaredLocales: [Locale]
    let whisperProvider: any WhisperLIDProvider
    let audioProvider: any AudioBufferProvider

    var initialLocale: Locale { declaredLocales[0] }
    let isBlocking = true

    func runDetection(continuation: AsyncStream<Locale>.Continuation) async throws -> Locale? {
        continuation.finish()
        return nil
    }
}
