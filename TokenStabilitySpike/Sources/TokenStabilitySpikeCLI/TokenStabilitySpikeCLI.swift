import Foundation
import TokenStabilityLib
import os

private let logger = Logger(
    subsystem: "com.speechcoach.app",
    category: "spike"
)

@main
struct TokenStabilitySpikeCLI {

    // Locked production constants from Spike #6
    private static let windowSize: TimeInterval = 6
    private static let emaAlpha: Double = 0.3
    private static let tokenSilenceTimeout: TimeInterval = 1.5
    private static let sampleInterval: TimeInterval = 3.0

    static func main() async throws {
        let args = CommandLine.arguments

        if args.contains("--diagnose") {
            await AudioFileProcessor.checkAssets()
            return
        }

        if args.contains("--help") || args.contains("-h") || args.count < 2 {
            printUsage()
            return
        }

        if args.contains("--header") {
            print(csvHeader)
            return
        }

        let audioPath = args[1]
        let tokensDirPath = parseTokensDir(from: args)

        let audioURL = URL(fileURLWithPath: audioPath)
        let jsonURL = audioURL
            .deletingPathExtension()
            .appendingPathExtension("json")

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            fputs("Error: Audio file not found: \(audioPath)\n", stderr)
            throw ExitError.fileNotFound
        }

        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            fputs("Error: Sidecar JSON not found: \(jsonURL.path)\n", stderr)
            throw ExitError.sidecarNotFound
        }

        let groundTruth = try AudioFileProcessor.loadGroundTruth(
            sidecarURL: jsonURL
        )

        logger.info(
            "Processing: \(groundTruth.clipName) [\(groundTruth.mic ?? "?"), \(groundTruth.environment ?? "?")]"
        )

        let result = try await AudioFileProcessor.process(
            audioFileURL: audioURL,
            groundTruth: groundTruth
        )

        logger.info("Recognized \(result.words.count) words")

        let row = buildCSVRow(result: result)
        print(row)

        if let tokensDir = tokensDirPath {
            try writeTokenCSV(
                words: result.words,
                clipName: groundTruth.clipName,
                directory: tokensDir
            )
        }
    }

    // MARK: - CSV Output

    static let csvHeader = [
        "clip_name", "mic", "environment",
        "gt_wpm", "gt_total_words", "duration_s",
        "words_recognized", "avg_wpm", "peak_wpm", "error_pct",
        "total_speaking_duration_s", "speaking_pct"
    ].joined(separator: ",")

    private static func buildCSVRow(result: ProcessingResult) -> String {
        let gt = result.groundTruth
        let words = result.words

        let calc = WPMCalculator(
            windowSize: windowSize,
            emaAlpha: emaAlpha,
            tokenSilenceTimeout: tokenSilenceTimeout
        )
        let samples = calc.processAll(
            words: words,
            sampleInterval: sampleInterval
        )

        let avgWPM: Double = samples.isEmpty
            ? 0
            : samples.map(\.smoothedWPM).reduce(0, +) / Double(samples.count)
        let peakWPM = samples.map(\.smoothedWPM).max() ?? 0
        let errorPct = gt.groundTruthWPM > 0
            ? abs(avgWPM - gt.groundTruthWPM) / gt.groundTruthWPM * 100.0
            : 0

        var tracker = SpeakingActivityTracker(
            tokenSilenceTimeout: tokenSilenceTimeout
        )
        for word in words { tracker.addToken(word) }
        let speakingDur: TimeInterval
        if let maxEnd = words.map(\.endTime).max() {
            speakingDur = tracker.speakingDuration(
                in: TimeRange(start: 0, end: maxEnd)
            )
        } else {
            speakingDur = 0
        }

        let speakingPct = gt.durationSeconds > 0
            ? speakingDur / gt.durationSeconds * 100.0
            : 0

        return [
            gt.clipName,
            gt.mic ?? "unknown",
            gt.environment ?? "unknown",
            String(format: "%.1f", gt.groundTruthWPM),
            "\(gt.totalWords)",
            String(format: "%.1f", gt.durationSeconds),
            "\(words.count)",
            String(format: "%.1f", avgWPM),
            String(format: "%.1f", peakWPM),
            String(format: "%.1f", errorPct),
            String(format: "%.1f", speakingDur),
            String(format: "%.1f", speakingPct)
        ].joined(separator: ",")
    }

    // MARK: - Token CSV Dump

    private static func writeTokenCSV(
        words: [TimestampedWord],
        clipName: String,
        directory: String
    ) throws {
        let dirURL = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(
            at: dirURL,
            withIntermediateDirectories: true
        )

        let fileURL = dirURL.appendingPathComponent(
            "\(clipName)_tokens.csv"
        )

        var lines = ["token,startTime,endTime"]
        for word in words {
            let escaped = word.word
                .replacingOccurrences(of: "\"", with: "\"\"")
            lines.append(String(format: "\"%@\",%.3f,%.3f",
                                escaped, word.startTime, word.endTime))
        }

        try lines.joined(separator: "\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)

        fputs("Wrote token CSV: \(fileURL.path)\n", stderr)
    }

    // MARK: - Argument Parsing

    private static func parseTokensDir(from args: [String]) -> String? {
        guard let idx = args.firstIndex(of: "--tokens-dir"),
              idx + 1 < args.count else {
            return nil
        }
        return args[idx + 1]
    }

    private static func printUsage() {
        let usage = """
            USAGE: TokenStabilitySpikeCLI <audio-file-path> [options]

            Processes one audio file through SpeechAnalyzer with locked
            production constants (window=6, alpha=0.3, tokenSilenceTimeout=1.5).
            Outputs a single CSV row to stdout.

            OPTIONS:
              --tokens-dir <dir>   Write per-clip token CSV to <dir>/<clipName>_tokens.csv
              --header             Print CSV header and exit
              --diagnose           Check SpeechTranscriber en-US asset availability
              --help, -h           Show this help message

            SIDECAR JSON FORMAT:
              Same base name as audio file. Required fields:
              clipName, language, paceLabel, groundTruthWPM, durationSeconds, totalWords
              Optional fields (stability spike):
              mic, environment, noiseSource, noiseVolume
            """
        print(usage)
    }
}

enum ExitError: Error {
    case fileNotFound
    case sidecarNotFound
}
