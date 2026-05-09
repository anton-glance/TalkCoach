import Foundation
import NaturalLanguage
import os

private nonisolated let logger = Logger(subsystem: "com.talkcoach.app", category: "lang")

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
        var text = ""
        let deadline = ContinuousClock.now + .seconds(6)
        for await partial in provider.partialTranscriptStream() {
            text += " " + partial
            if ContinuousClock.now >= deadline { break }
            if Task.isCancelled { break }
        }

        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            continuation.finish()
            return nil
        }

        let recognizer = NLLanguageRecognizer()
        let nlLanguages = declaredLocales.map {
            NLLanguage(rawValue: $0.language.languageCode?.identifier ?? "")
        }
        recognizer.languageConstraints = nlLanguages
        recognizer.processString(text)

        guard let detected = recognizer.dominantLanguage else {
            continuation.finish()
            return nil
        }

        let detectedLocale = declaredLocales.first {
            ($0.language.languageCode?.identifier ?? "") == detected.rawValue
        }

        if let detectedLocale, detectedLocale.identifier != declaredLocales[0].identifier {
            let wordCount = text.split(separator: " ").count
            logger.info("LanguageDetector: Strategy 1 swap fired \(self.declaredLocales[0].identifier) → \(detectedLocale.identifier) after \(wordCount) words")
            continuation.yield(detectedLocale)
            continuation.finish()
            return detectedLocale
        }

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
        var text = ""
        var receivedPartials = false
        let deadline = ContinuousClock.now + .seconds(6)
        for await partial in provider.partialTranscriptStream() {
            receivedPartials = true
            text += " " + partial
            if ContinuousClock.now >= deadline { break }
            if Task.isCancelled { break }
        }

        guard receivedPartials else {
            continuation.finish()
            return nil
        }

        let wordCount = text.split(separator: " ").count

        if wordCount < Self.wordCountThreshold {
            let swapped = declaredLocales[1]
            logger.info("LanguageDetector: Strategy 2 swap fired \(self.declaredLocales[0].identifier) → \(swapped.identifier) (word count \(wordCount) < threshold \(Self.wordCountThreshold))")
            continuation.yield(swapped)
            continuation.finish()
            return swapped
        }

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
        var buffers: [CapturedAudioBuffer] = []
        var accumulatedFrames: Double = 0
        let targetSeconds: Double = 3.0
        let deadline = ContinuousClock.now + .seconds(6)

        for await buffer in audioProvider.bufferStream() {
            buffers.append(buffer)
            accumulatedFrames += Double(buffer.frameLength)
            let seconds = accumulatedFrames / buffer.sampleRate
            if seconds >= targetSeconds { break }
            if ContinuousClock.now >= deadline { break }
            if Task.isCancelled { break }
        }

        do {
            let detected = try await whisperProvider.detectLanguage(
                from: buffers,
                constrainedTo: declaredLocales
            )
            logger.info("LanguageDetector: Strategy 3 committed \(detected.identifier)")
            continuation.finish()
            return detected
        } catch is WhisperLIDProviderError {
            logger.warning("Whisper-tiny model unavailable, falling back to declaredLocales[0] best-guess")
            continuation.finish()
            return nil
        }
    }
}
