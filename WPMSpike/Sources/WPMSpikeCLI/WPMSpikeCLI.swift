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

        if args.contains("--help") || args.contains("-h") || args.count < 2 {
            printUsage()
            return
        }

        let audioPath = args[1]
        let vadThreshold = parseVADThreshold(from: args)

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
            groundTruth: groundTruth,
            vadThreshold: vadThreshold
        )

        logger.info("Recognized \(result.words.count) words, \(result.vadEvents.count) VAD events")

        printCSVHeader()
        printCSVRows(result: result, groundTruth: groundTruth)
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
        groundTruth: GroundTruth
    ) {
        for windowSize in windowSizes {
            for alpha in alphas {
                let calc = WPMCalculator(
                    windowSize: windowSize,
                    emaAlpha: alpha
                )
                let samples = calc.processAll(
                    words: result.words,
                    vadEvents: result.vadEvents,
                    sampleInterval: 3.0
                )
                printCSVRow(
                    groundTruth: groundTruth,
                    windowSize: windowSize,
                    alpha: alpha,
                    samples: samples,
                    wordsRecognized: result.words.count
                )
            }
        }
    }

    private static func printCSVRow(
        groundTruth: GroundTruth,
        windowSize: TimeInterval,
        alpha: Double,
        samples: [WPMSample],
        wordsRecognized: Int
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
            String(format: "%.0f", windowSize),
            String(format: "%.1f", alpha),
            String(format: "%.1f", avgWPM),
            String(format: "%.1f", peakWPM),
            String(format: "%.1f", errorPct),
            "\(wordsRecognized)"
        ].joined(separator: ",")

        print(row)
    }

    private static func printUsage() {
        let usage = """
            USAGE: WPMSpikeCLI <audio-file-path> [--vad-threshold <dBFS>]

            Reads a .wav/.caf audio file and its sidecar .json metadata.
            Processes through SpeechAnalyzer to extract timestamped words.
            Computes WPM using all (window-size, alpha) combinations.
            Outputs CSV to stdout.

            OPTIONS:
              --vad-threshold <dBFS>   VAD threshold in dBFS (default: -40.0)
              --help, -h               Show this help message

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
            "avg_wpm", "peak_wpm", "error_pct", "words_recognized"
        ].joined(separator: ",")
        print(header)
    }

    private static func parseVADThreshold(from args: [String]) -> Float {
        guard let idx = args.firstIndex(of: "--vad-threshold"),
              idx + 1 < args.count,
              let value = Float(args[idx + 1]) else {
            return -40.0
        }
        return value
    }
}

enum ExitError: Error {
    case fileNotFound
    case sidecarNotFound
}
