import AVFAudio
import Foundation
import Speech
import WPMCalculatorLib
import os

private let logger = Logger(
    subsystem: "com.speechcoach.app",
    category: "spike"
)

struct GroundTruth: Codable, Sendable {
    let clipName: String
    let language: String
    let paceLabel: String
    let groundTruthWPM: Double
    let durationSeconds: Double
    let totalWords: Int
}

struct ProcessingResult: Sendable {
    let groundTruth: GroundTruth
    let words: [TimestampedWord]
    let audioDuration: TimeInterval
}

enum AudioFileProcessor {

    static func loadGroundTruth(sidecarURL: URL) throws -> GroundTruth {
        let data = try Data(contentsOf: sidecarURL)
        return try JSONDecoder().decode(GroundTruth.self, from: data)
    }

    static func process(
        audioFileURL: URL,
        groundTruth: GroundTruth
    ) async throws -> ProcessingResult {
        let transcriber = try await makeTranscriber(
            language: groundTruth.language
        )

        let audioFile = try AVAudioFile(forReading: audioFileURL)
        let sampleRate = audioFile.processingFormat.sampleRate
        let audioDuration = Double(audioFile.length) / sampleRate

        _ = try await SpeechAnalyzer(
            inputAudioFile: audioFile,
            modules: [transcriber],
            finishAfterFile: true
        )

        let words = try await collectWords(from: transcriber)

        return ProcessingResult(
            groundTruth: groundTruth,
            words: words,
            audioDuration: audioDuration
        )
    }

    // MARK: - Private

    private static func makeTranscriber(
        language: String
    ) async throws -> SpeechTranscriber {
        let locale = Locale(identifier: language)

        guard let supported = await SpeechTranscriber
            .supportedLocale(equivalentTo: locale) else {
            throw ProcessingError.unsupportedLocale(language)
        }

        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        if let req = try await AssetInventory
            .assetInstallationRequest(supporting: [transcriber]) {
            logger.info("Downloading speech model for \(language)...")
            try await req.downloadAndInstall()
        }

        return transcriber
    }

    private static func collectWords(
        from transcriber: SpeechTranscriber
    ) async throws -> [TimestampedWord] {
        var words: [TimestampedWord] = []

        for try await result in transcriber.results {
            let text = result.text

            for run in text.runs {
                let key = AttributeScopes
                    .SpeechAttributes.TimeRangeAttribute.self
                guard let timeRange = run[key] else { continue }

                let raw = String(text[run.range].characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()

                guard !raw.isEmpty else { continue }

                let start = CMTimeGetSeconds(timeRange.start)
                let end = CMTimeGetSeconds(timeRange.end)

                for part in raw.split(separator: " ") {
                    words.append(TimestampedWord(
                        word: String(part),
                        startTime: start,
                        endTime: end
                    ))
                }
            }

            if String(text.characters).isEmpty {
                logger.debug("Empty result (no speech in segment)")
            }
        }

        return words
    }
}

enum ProcessingError: Error, CustomStringConvertible {
    case unsupportedLocale(String)

    var description: String {
        switch self {
        case .unsupportedLocale(let locale):
            return "Locale '\(locale)' not supported by SpeechTranscriber."
        }
    }
}
