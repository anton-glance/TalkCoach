import FluidAudio
import Foundation
import WPMCalcCopy
import os

private let logger = Logger(
    subsystem: "com.speechcoach.app",
    category: "parakeet-spike"
)

@main
struct ParakeetSpikeCLI {

    static func main() async throws {
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            printUsage()
            return
        }

        if args.contains("--download-model") {
            try await downloadModel()
            return
        }

        if let idx = args.firstIndex(of: "--transcribe"),
            idx + 1 < args.count
        {
            let audioPath = args[idx + 1]
            try await runTranscription(audioPath: audioPath)
            return
        }

        if let idx = args.firstIndex(of: "--validate-all"),
            idx + 1 < args.count
        {
            let recordingsDir = args[idx + 1]
            try await runFullValidation(recordingsDir: recordingsDir)
            return
        }

        printUsage()
    }

    // MARK: - Commands

    private static func downloadModel() async throws {
        let startTime = Date()
        fputs("Downloading Parakeet v3 model...\n", stderr)

        let models = try await AsrModels.downloadAndLoad(
            version: .v3
        )

        let elapsed = Date().timeIntervalSince(startTime)
        fputs(
            "Model download+load complete in "
                + "\(String(format: "%.1f", elapsed))s\n",
            stderr
        )

        let asrManager = AsrManager(models: models)
        fputs("AsrManager initialized. Model ready.\n", stderr)
    }

    private static func runTranscription(
        audioPath: String
    ) async throws {
        let audioURL = URL(fileURLWithPath: audioPath)
        guard FileManager.default.fileExists(atPath: audioPath) else {
            fputs("Error: file not found: \(audioPath)\n", stderr)
            return
        }

        let loadStart = Date()
        let models = try await AsrModels.downloadAndLoad(
            version: .v3
        )
        let loadElapsed = Date().timeIntervalSince(loadStart)
        fputs(
            "Model load: \(String(format: "%.1f", loadElapsed))s\n",
            stderr
        )

        let asrManager = AsrManager(models: models)
        let result = try await Transcriber.transcribe(
            audioURL: audioURL,
            asrManager: asrManager,
            language: .russian
        )

        fputs(
            "Audio: \(String(format: "%.1f", result.audioDuration))s, "
                + "Processing: \(String(format: "%.2f", result.processingTime))s, "
                + "RTF: \(String(format: "%.4f", result.rtf)), "
                + "Words: \(result.words.count)\n",
            stderr
        )

        Transcriber.emitCSV(words: result.words)
    }

    private static func runFullValidation(
        recordingsDir: String
    ) async throws {
        let clips = ["ru_normal", "ru_fast", "ru_slow"]
        let russianFillers = ["ну", "это", "как бы", "типа", "короче"]

        let loadStart = Date()
        let models = try await AsrModels.downloadAndLoad(
            version: .v3
        )
        let compileLoadTime = Date().timeIntervalSince(loadStart)
        fputs(
            "Model compile+load: "
                + "\(String(format: "%.1f", compileLoadTime))s\n",
            stderr
        )

        let asrManager = AsrManager(models: models)

        var allWER: [String] = []
        var allTimestamps: [String] = []
        var allFillers: [String] = []

        allWER.append(
            "clip,wer,ref_words,sub,ins,del"
        )
        allTimestamps.append(
            "clip,gt_wpm,computed_wpm,error_pct,word_count,"
                + "speaking_duration_s,granularity,avg_gap_s,median_dur_s"
        )
        allFillers.append(
            "clip,filler,expected,recognized,rate"
        )

        for clip in clips {
            let audioPath = "\(recordingsDir)/\(clip).caf"
            let transcriptPath =
                "\(recordingsDir)/transcripts/\(clip).txt"
            let jsonPath = "\(recordingsDir)/\(clip).json"

            guard FileManager.default.fileExists(atPath: audioPath) else {
                fputs("Skipping \(clip) — no .caf file\n", stderr)
                continue
            }

            fputs("Processing \(clip)...\n", stderr)

            let audioURL = URL(fileURLWithPath: audioPath)
            let result = try await Transcriber.transcribe(
                audioURL: audioURL,
                asrManager: asrManager,
                language: .russian
            )

            fputs(
                "  RTF: \(String(format: "%.4f", result.rtf)), "
                    + "Words: \(result.words.count)\n",
                stderr
            )

            // Save raw token CSV
            let tokenCSVPath =
                "\(recordingsDir)/../results/\(clip)_tokens.csv"
            let tokenCSV = "token,startTime,endTime,confidence\n"
                + result.words.map { w in
                    let esc = w.word.replacingOccurrences(
                        of: "\"", with: "\"\""
                    )
                    return "\"\(esc)\","
                        + "\(String(format: "%.3f", w.startTime)),"
                        + "\(String(format: "%.3f", w.endTime)),"
                        + "\(String(format: "%.4f", w.confidence))"
                }.joined(separator: "\n")
            try tokenCSV.write(
                toFile: tokenCSVPath,
                atomically: true,
                encoding: .utf8
            )

            // WER
            if FileManager.default.fileExists(atPath: transcriptPath) {
                let refText = try String(
                    contentsOfFile: transcriptPath, encoding: .utf8
                )
                let werResult = WERCalculator.compute(
                    hypothesis: result.words,
                    referenceText: refText
                )
                allWER.append(
                    "\(clip),"
                        + "\(String(format: "%.3f", werResult.wer)),"
                        + "\(werResult.referenceCount),"
                        + "\(werResult.substitutions),"
                        + "\(werResult.insertions),"
                        + "\(werResult.deletions)"
                )
                fputs(
                    "  WER: \(String(format: "%.1f", werResult.wer * 100))%\n",
                    stderr
                )

                let fillerResults = WERCalculator
                    .computeFillerRecognition(
                        hypothesis: result.words,
                        referenceText: refText,
                        fillers: russianFillers
                    )
                for fr in fillerResults {
                    allFillers.append(
                        "\(clip),\(fr.filler),"
                            + "\(fr.expectedCount),"
                            + "\(fr.recognizedCount),"
                            + "\(String(format: "%.2f", fr.rate))"
                    )
                }
            }

            // Timestamp validation + WPM
            if FileManager.default.fileExists(atPath: jsonPath) {
                let jsonData = try Data(
                    contentsOf: URL(fileURLWithPath: jsonPath)
                )
                let gt = try JSONDecoder().decode(
                    GroundTruth.self, from: jsonData
                )
                let validation = TimestampValidator.validate(
                    words: result.words,
                    clipName: clip,
                    groundTruthWPM: gt.groundTruthWPM
                )
                allTimestamps.append(
                    "\(validation.clipName),"
                        + "\(String(format: "%.1f", validation.groundTruthWPM)),"
                        + "\(String(format: "%.1f", validation.computedWPM)),"
                        + "\(String(format: "%.1f", validation.errorPercent)),"
                        + "\(validation.wordCount),"
                        + "\(String(format: "%.1f", validation.speakingDuration)),"
                        + "\(validation.timestampGranularity),"
                        + "\(String(format: "%.4f", validation.averageGapBetweenWords)),"
                        + "\(String(format: "%.4f", validation.medianTokenDuration))"
                )
                fputs(
                    "  WPM: \(String(format: "%.1f", validation.computedWPM)) "
                        + "(gt: \(String(format: "%.1f", validation.groundTruthWPM)), "
                        + "err: \(String(format: "%.1f", validation.errorPercent))%)\n",
                    stderr
                )
            }
        }

        // Write result CSVs
        let resultsDir = "\(recordingsDir)/../results"
        try FileManager.default.createDirectory(
            atPath: resultsDir,
            withIntermediateDirectories: true
        )

        try allWER.joined(separator: "\n").write(
            toFile: "\(resultsDir)/wer.csv",
            atomically: true,
            encoding: .utf8
        )
        try allTimestamps.joined(separator: "\n").write(
            toFile: "\(resultsDir)/timestamps.csv",
            atomically: true,
            encoding: .utf8
        )
        try allFillers.joined(separator: "\n").write(
            toFile: "\(resultsDir)/fillers.csv",
            atomically: true,
            encoding: .utf8
        )

        fputs(
            "\nResults written to \(resultsDir)/\n",
            stderr
        )

        // Print summary to stdout
        print("=== WER ===")
        for line in allWER { print(line) }
        print("\n=== TIMESTAMPS + WPM ===")
        for line in allTimestamps { print(line) }
        print("\n=== FILLERS ===")
        for line in allFillers { print(line) }
    }

    private static func printUsage() {
        let usage = """
            USAGE: ParakeetSpikeCLI <command> [options]

            COMMANDS:
              --download-model              Download Parakeet v3 model
              --transcribe <audio-path>     Transcribe a single audio file
              --validate-all <recordings-dir>  Run full validation suite
              --help, -h                    Show this help

            EXAMPLES:
              ParakeetSpikeCLI --download-model
              ParakeetSpikeCLI --transcribe ../WPMSpike/recordings/ru_normal.caf
              ParakeetSpikeCLI --validate-all ../WPMSpike/recordings
            """
        print(usage)
    }
}

struct GroundTruth: Codable {
    let clipName: String
    let language: String
    let paceLabel: String
    let groundTruthWPM: Double
    let durationSeconds: Double
    let totalWords: Int
}
