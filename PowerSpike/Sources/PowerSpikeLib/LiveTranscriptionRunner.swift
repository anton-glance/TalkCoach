@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech
import os

private let logger = Logger(
    subsystem: "com.talkcoach.app",
    category: "power-spike"
)

public actor LiveTranscriptionRunner {
    private var wordCount: Int = 0
    private var wpmCalculator: WPMCalculator
    private var tracker: SpeakingActivityTracker

    public init() {
        wpmCalculator = WPMCalculator(
            windowSize: 6.0,
            emaAlpha: 0.3,
            tokenSilenceTimeout: 1.5
        )
        tracker = SpeakingActivityTracker(tokenSilenceTimeout: 1.5)
    }

    public func snapshot(elapsed: TimeInterval) -> TranscriptionSnapshot {
        let sample = wpmCalculator.wpm(at: elapsed)
        return TranscriptionSnapshot(
            wordCount: wordCount,
            speakingDuration: wpmCalculator.totalSpeakingDuration,
            avgWPM: sample.smoothedWPM
        )
    }

    private func addWord(_ word: TimestampedWord) {
        wordCount += 1
        wpmCalculator.addWord(word)
        tracker.addToken(word)
    }

    public static func checkAssets() async {
        fputs("=== Preflight: SpeechTranscriber asset check ===\n", stderr)

        let enLocale = Locale(identifier: "en")
        guard let supported = await SpeechTranscriber
            .supportedLocale(equivalentTo: enLocale) else {
            fputs(
                "FAIL: en not in SpeechTranscriber.supportedLocales\n",
                stderr
            )
            return
        }
        fputs("en supported as: \(supported.identifier)\n", stderr)

        let installed = await SpeechTranscriber.installedLocales
        let enInstalled = installed.contains {
            $0.identifier.hasPrefix("en")
        }
        fputs("en installed: \(enInstalled)\n", stderr)

        if !enInstalled {
            fputs("Attempting asset download...\n", stderr)
            let transcriber = SpeechTranscriber(
                locale: supported,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )
            do {
                if let req = try await AssetInventory
                    .assetInstallationRequest(supporting: [transcriber])
                {
                    try await req.downloadAndInstall()
                    fputs("Download succeeded.\n", stderr)
                } else {
                    fputs(
                        "Already installed (no request needed).\n",
                        stderr
                    )
                }
            } catch {
                fputs("FAIL: asset download error: \(error)\n", stderr)
            }
        }

        fputs("=== Preflight complete ===\n", stderr)
    }

    public func startTranscribing(
        bufferRelay: BufferRelay,
        sourceFormat: AVAudioFormat
    ) async throws {
        let enLocale = Locale(identifier: "en")
        guard let supported = await SpeechTranscriber
            .supportedLocale(equivalentTo: enLocale) else {
            throw TranscriptionError.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        if let req = try await AssetInventory
            .assetInstallationRequest(supporting: [transcriber])
        {
            logger.info("Downloading speech model for en...")
            try await req.downloadAndInstall()
        }

        let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: sourceFormat
        )

        fputs(
            "Source format: \(sourceFormat.sampleRate) Hz, \(sourceFormat.channelCount) ch\n",
            stderr
        )
        if let tf = targetFormat {
            fputs(
                "Target format: \(tf.sampleRate) Hz, \(tf.channelCount) ch\n",
                stderr
            )
        } else {
            fputs("Target format: nil (using source format)\n", stderr)
        }

        let converter: AVAudioConverter?
        let analyzerFormat: AVAudioFormat
        if let tf = targetFormat, tf != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: tf)
            analyzerFormat = tf
            fputs("Audio converter created.\n", stderr)
        } else {
            converter = nil
            analyzerFormat = sourceFormat
            fputs("No conversion needed.\n", stderr)
        }

        let (inputStream, inputContinuation) = AsyncStream.makeStream(
            of: AnalyzerInput.self
        )

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try await analyzer.start(inputSequence: inputStream)
        logger.info("SpeechAnalyzer started on live mic input")
        fputs("SpeechAnalyzer started.\n", stderr)

        let feedTask = Task.detached { [converter] in
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(50))
                let buffers = bufferRelay.drainAll()
                for buffer in buffers {
                    let analyzerBuffer: AVAudioPCMBuffer
                    if let converter {
                        let ratio =
                            analyzerFormat.sampleRate
                            / buffer.format.sampleRate
                        let outFrameCount = AVAudioFrameCount(
                            Double(buffer.frameLength) * ratio
                        ) + 1
                        guard
                            let converted = AVAudioPCMBuffer(
                                pcmFormat: analyzerFormat,
                                frameCapacity: outFrameCount
                            )
                        else { continue }

                        var error: NSError?
                        let sourceBuffer = buffer
                        converter.convert(
                            to: converted, error: &error,
                            withInputFrom: convertInputBlock(
                                source: sourceBuffer
                            )
                        )
                        if let error {
                            fputs(
                                "Conversion error: \(error)\n",
                                stderr
                            )
                            continue
                        }
                        analyzerBuffer = converted
                    } else {
                        analyzerBuffer = buffer
                    }
                    inputContinuation.yield(
                        AnalyzerInput(buffer: analyzerBuffer)
                    )
                }
            }
            inputContinuation.finish()
        }

        do {
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
                        let word = TimestampedWord(
                            word: String(part),
                            startTime: start,
                            endTime: end
                        )
                        addWord(word)
                    }
                }
            }
        } catch {
            logger.error("Transcription error: \(error)")
            fputs("Transcription error: \(error)\n", stderr)
        }

        feedTask.cancel()
    }
}

public struct TranscriptionSnapshot: Sendable {
    public let wordCount: Int
    public let speakingDuration: TimeInterval
    public let avgWPM: Double
}

enum TranscriptionError: Error {
    case unsupportedLocale
}

private final class OneShotFlag: @unchecked Sendable {
    private var _consumed = false
    func consume() -> Bool {
        if _consumed { return false }
        _consumed = true
        return true
    }
}

private func convertInputBlock(
    source: AVAudioPCMBuffer
) -> AVAudioConverterInputBlock {
    let flag = OneShotFlag()
    return { _, outStatus in
        if flag.consume() {
            outStatus.pointee = .haveData
            return source
        }
        outStatus.pointee = .noDataNow
        return nil
    }
}
