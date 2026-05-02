import AVFoundation
import FluidAudio
import Foundation
import os

private let logger = Logger(
    subsystem: "com.speechcoach.app",
    category: "parakeet-transcriber"
)

enum Transcriber {

    struct TranscriptionResult: Sendable {
        let words: [MergedWord]
        let rawText: String
        let processingTime: TimeInterval
        let audioDuration: TimeInterval
        let rtf: Double
    }

    static func transcribe(
        audioURL: URL,
        asrManager: AsrManager,
        language: Language? = nil
    ) async throws -> TranscriptionResult {
        let startTime = Date()

        var decoderState = try TdtDecoderState()
        let result = try await asrManager.transcribe(
            audioURL, decoderState: &decoderState, language: language
        )

        let processingTime = Date().timeIntervalSince(startTime)

        let rawTokens: [(token: String, startTime: Double, endTime: Double, confidence: Float)]
            = (result.tokenTimings ?? []).map { timing in
                return (
                    token: timing.token,
                    startTime: timing.startTime,
                    endTime: timing.endTime,
                    confidence: timing.confidence
                )
            }

        let mergedWords = TokenMerger.merge(tokens: rawTokens)

        let audioFile = try AVAudioFile(forReading: audioURL)
        let audioDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        let rtf = audioDuration > 0 ? processingTime / audioDuration : 0

        logger.info(
            "Transcribed \(audioURL.lastPathComponent): \(mergedWords.count) words, RTF=\(String(format: "%.4f", rtf))"
        )

        return TranscriptionResult(
            words: mergedWords,
            rawText: result.text,
            processingTime: processingTime,
            audioDuration: audioDuration,
            rtf: rtf
        )
    }

    static func emitCSV(words: [MergedWord]) {
        print("token,startTime,endTime,confidence")
        for w in words {
            let escaped = w.word
                .replacingOccurrences(of: "\"", with: "\"\"")
            print(
                "\"\(escaped)\","
                    + "\(String(format: "%.3f", w.startTime)),"
                    + "\(String(format: "%.3f", w.endTime)),"
                    + "\(String(format: "%.4f", w.confidence))"
            )
        }
    }
}
