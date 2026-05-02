import Foundation
import WPMCalculatorLib
import os

private let logger = Logger(
    subsystem: "com.speechcoach.app",
    category: "spike"
)

@main
struct WPMSpikeCLI {

    private static let windowSizes: [TimeInterval] = [5, 6, 8, 10]
    private static let alphas: [Double] = [0.2, 0.3, 0.4]

    static func main() async throws {
        let args = CommandLine.arguments

        if args.contains("--diagnose") {
            await Diagnostics.run()
            return
        }

        if args.contains("--help") || args.contains("-h") || args.count < 2 {
            printUsage()
            return
        }

        let audioPath = args[1]
        let timeout = parseTokenSilenceTimeout(from: args)

        let audioURL = URL(fileURLWithPath: audioPath)
        let jsonExt = audioURL
            .deletingPathExtension()
            .appendingPathExtension("json")

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            fputs("Error: Audio file not found: \(audioPath)\n", stderr)
            throw ExitError.fileNotFound
        }

        guard FileManager.default.fileExists(atPath: jsonExt.path) else {
            fputs("Error: Sidecar JSON not found: \(jsonExt.path)\n", stderr)
            throw ExitError.sidecarNotFound
        }

        let groundTruth = try AudioFileProcessor.loadGroundTruth(
            sidecarURL: jsonExt
        )

        logProcessingStart(groundTruth)

        let result = try await AudioFileProcessor.process(
            audioFileURL: audioURL,
            groundTruth: groundTruth
        )

        logger.info("Recognized \(result.words.count) words")

        printCSVHeader()
        printCSVRows(
            result: result,
            groundTruth: groundTruth,
            tokenSilenceTimeout: timeout
        )
    }

    // MARK: - Output

    private static func logProcessingStart(_ groundTruth: GroundTruth) {
        logger.info(
            "Processing: \(groundTruth.clipName) (\(groundTruth.language), \(groundTruth.paceLabel))"
        )
        let wpm = groundTruth.groundTruthWPM
        let words = groundTruth.totalWords
        let dur = groundTruth.durationSeconds
        logger.info("Ground truth: \(wpm) WPM, \(words) words, \(dur)s")
    }

    private static func printCSVRows(
        result: ProcessingResult,
        groundTruth: GroundTruth,
        tokenSilenceTimeout: TimeInterval
    ) {
        let speakingDur = computeSpeakingDuration(
            words: result.words,
            tokenSilenceTimeout: tokenSilenceTimeout
        )

        for windowSize in windowSizes {
            for alpha in alphas {
                let calc = WPMCalculator(
                    windowSize: windowSize,
                    emaAlpha: alpha,
                    tokenSilenceTimeout: tokenSilenceTimeout
                )
                let samples = calc.processAll(
                    words: result.words,
                    sampleInterval: 3.0
                )
                printCSVRow(
                    groundTruth: groundTruth,
                    samples: samples,
                    config: CSVRowConfig(
                        windowSize: windowSize,
                        alpha: alpha,
                        tokenSilenceTimeout: tokenSilenceTimeout,
                        wordsRecognized: result.words.count,
                        totalSpeakingDuration: speakingDur
                    )
                )
            }
        }
    }

    private static func computeSpeakingDuration(
        words: [TimestampedWord],
        tokenSilenceTimeout: TimeInterval
    ) -> TimeInterval {
        guard !words.isEmpty else { return 0 }
        var tracker = SpeakingActivityTracker(
            tokenSilenceTimeout: tokenSilenceTimeout
        )
        for word in words { tracker.addToken(word) }
        if let maxEnd = words.map(\.endTime).max() {
            return tracker.speakingDuration(
                in: TimeRange(start: 0, end: maxEnd)
            )
        }
        return 0
    }

    private struct CSVRowConfig {
        let windowSize: TimeInterval
        let alpha: Double
        let tokenSilenceTimeout: TimeInterval
        let wordsRecognized: Int
        let totalSpeakingDuration: TimeInterval
    }

    private static func printCSVRow(
        groundTruth: GroundTruth,
        samples: [WPMSample],
        config: CSVRowConfig
    ) {
        let avgWPM: Double = samples.isEmpty
            ? 0
            : samples.map(\.smoothedWPM).reduce(0, +) / Double(samples.count)
        let peakWPM = samples.map(\.smoothedWPM).max() ?? 0
        let gtWPM = groundTruth.groundTruthWPM
        let errorPct = gtWPM > 0
            ? abs(avgWPM - gtWPM) / gtWPM * 100.0
            : 0

        let row = [
            groundTruth.clipName,
            groundTruth.language,
            groundTruth.paceLabel,
            String(format: "%.1f", gtWPM),
            "\(groundTruth.totalWords)",
            String(format: "%.1f", groundTruth.durationSeconds),
            String(format: "%.0f", config.windowSize),
            String(format: "%.1f", config.alpha),
            String(format: "%.1f", config.tokenSilenceTimeout),
            String(format: "%.1f", avgWPM),
            String(format: "%.1f", peakWPM),
            String(format: "%.1f", errorPct),
            "\(config.wordsRecognized)",
            String(format: "%.1f", config.totalSpeakingDuration)
        ].joined(separator: ",")

        print(row)
    }

    private static func printUsage() {
        let usage = """
            USAGE: WPMSpikeCLI <audio-file-path> [options]

            Reads a .wav/.caf audio file and its sidecar .json metadata.
            Processes through SpeechAnalyzer to extract timestamped words.
            Computes WPM using all (window-size, alpha) combinations.
            Outputs CSV to stdout.

            No calibration is required. Speaking duration is derived from
            SpeechAnalyzer token timestamps directly.

            OPTIONS:
              --token-silence-timeout <s>    Max gap between tokens treated as speech (default: 1.5)
              --help, -h                     Show this help message

            SIDECAR JSON FORMAT:
              Same base name as audio file. Fields:
              clipName, language, paceLabel, groundTruthWPM,
              durationSeconds, totalWords
            """
        print(usage)
    }

    private static func printCSVHeader() {
        let header = [
            "clip_name", "language", "pace", "gt_wpm",
            "gt_total_words", "duration_s", "window_s", "alpha",
            "token_silence_timeout_s",
            "avg_wpm", "peak_wpm", "error_pct",
            "words_recognized", "total_speaking_duration_s"
        ].joined(separator: ",")
        print(header)
    }

    private static func parseTokenSilenceTimeout(
        from args: [String]
    ) -> TimeInterval {
        guard let idx = args.firstIndex(of: "--token-silence-timeout"),
              idx + 1 < args.count,
              let value = Double(args[idx + 1]) else {
            return 1.5
        }
        return value
    }
}

enum ExitError: Error {
    case fileNotFound
    case sidecarNotFound
}
