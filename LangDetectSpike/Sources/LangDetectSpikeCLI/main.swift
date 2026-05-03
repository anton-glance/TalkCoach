import Foundation
import LangDetectSpikeLib
import os

private let logger = Logger(
    subsystem: "com.speechcoach.app",
    category: "spike.langdetect"
)

enum Subcommand: String {
    case preflight
    case evaluateB = "evaluate-b"
    case evaluateC = "evaluate-c"
    case analyzeWordcount = "analyze-wordcount"
}

@main
struct LangDetectSpikeCLI {

    static func main() async throws {
        let args = CommandLine.arguments

        guard args.count >= 2 else {
            printUsage()
            return
        }

        guard let subcommand = Subcommand(rawValue: args[1]) else {
            if args[1] == "--help" || args[1] == "-h" {
                printUsage()
                return
            }
            fputs("Error: unknown subcommand '\(args[1])'\n", stderr)
            printUsage()
            throw ExitError.unknownSubcommand
        }

        switch subcommand {
        case .preflight:
            try await runPreflight(args: args)
        case .evaluateB:
            try await runEvaluateB(args: args)
        case .evaluateC:
            try await runEvaluateC(args: args)
        case .analyzeWordcount:
            try runAnalyzeWordcount(args: args)
        }
    }

    // MARK: - Preflight

    private static func runPreflight(args: [String]) async throws {
        let manifestPath = try parseRequiredArg("--manifest", from: args)
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let manifest = try ClipManifest.load(from: manifestURL)

        let recordingsDir = manifestURL.deletingLastPathComponent()

        print("Preflight checks for Spike #2 harness")
        print("======================================")
        print("Manifest: \(manifest.clips.count) clips")

        for lang in ["en", "ru", "ja", "es"] {
            let clips = manifest.clips(forLanguage: lang)
            let allExist = clips.allSatisfy { clip in
                FileManager.default.fileExists(
                    atPath: recordingsDir.appendingPathComponent(clip.filename).path
                )
            }
            let status = clips.isEmpty ? "no clips" : (allExist ? "OK" : "MISSING FILES")
            print("  \(lang): \(clips.count) clips — \(status)")
        }

        print("")
        print("SpeechTranscriber locale check:")
        print("  (Phase B will verify locale model downloads at runtime)")
        print("")
        print("NLLanguageRecognizer sanity check:")
        try runNLLanguageRecognizerSanityCheck()
        print("")
        print("Parakeet model cache check:")
        checkParakeetModelCache()
        print("")
        print("Preflight complete.")
    }

    private static func runNLLanguageRecognizerSanityCheck() throws {
        // Deferred to Phase B — requires NaturalLanguage import and real text.
        // Placeholder reports the check will happen at evaluation time.
        print("  (Deferred to Phase B — sanity check runs before first evaluation)")
    }

    private static func checkParakeetModelCache() {
        let cacheDir = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first
        if let cacheDir {
            let fluidPath = cacheDir.appendingPathComponent("FluidAudio")
            let exists = FileManager.default.fileExists(atPath: fluidPath.path)
            print("  FluidAudio cache dir: \(exists ? "EXISTS" : "NOT FOUND") at \(fluidPath.path)")
            if exists {
                print("  (Parakeet model likely cached from ParakeetSpike — no fresh download expected)")
            } else {
                print("  (First Russian evaluation will trigger ~1.2 GB model download)")
            }
        } else {
            print("  Could not determine cache directory")
        }
    }

    // MARK: - Evaluate B

    private static func runEvaluateB(args: [String]) async throws {
        if args.contains("--header") {
            print(OptionBResult.csvHeader)
            return
        }

        let clipPath = try parseRequiredArg("--clip", from: args)
        let pair = try parseRequiredArg("--pair", from: args)
        let guessModeStr = try parseRequiredArg("--guess-mode", from: args)
        let manifestPath = try parseRequiredArg("--manifest", from: args)

        guard let guessMode = OptionBResult.GuessMode(rawValue: guessModeStr) else {
            fputs("Error: --guess-mode must be 'wrong' or 'correct'\n", stderr)
            throw ExitError.invalidArgument
        }

        let manifest = try ClipManifest.load(from: URL(fileURLWithPath: manifestPath))
        let clipFilename = URL(fileURLWithPath: clipPath).lastPathComponent

        guard let clipEntry = manifest.clips.first(where: { $0.filename == clipFilename }) else {
            fputs("Error: clip '\(clipFilename)' not found in manifest\n", stderr)
            throw ExitError.clipNotInManifest
        }

        let pairParts = pair.split(separator: "+").map(String.init)
        guard pairParts.count == 2 else {
            fputs("Error: --pair must be in format 'en+ru'\n", stderr)
            throw ExitError.invalidArgument
        }

        let groundTruth = clipEntry.language
        let initializedLang: String
        if guessMode == .wrong {
            initializedLang = (groundTruth == pairParts[0]) ? pairParts[1] : pairParts[0]
        } else {
            initializedLang = groundTruth
        }

        logger.info(
            "evaluate-b: clip=\(clipFilename) pair=\(pair) guess=\(guessModeStr) ground_truth=\(groundTruth) initialized=\(initializedLang)"
        )

        // --- Phase B placeholder ---
        // Actual transcription + NLLanguageRecognizer evaluation will be
        // implemented in Phase B. For now, emit a placeholder row indicating
        // the harness argument parsing and routing works correctly.
        fputs(
            "evaluate-b: NOT YET IMPLEMENTED — Phase B adds transcription + detection logic\n",
            stderr
        )
        fputs(
            "  Would evaluate: \(clipFilename) with \(initializedLang) transcriber, "
            + "detect among [\(pair)], guess_mode=\(guessModeStr)\n",
            stderr
        )

        let placeholder = OptionBResult(
            clip: clipFilename,
            pair: pair,
            groundTruthLang: groundTruth,
            initializedLang: initializedLang,
            guessMode: guessMode,
            partialText: "<placeholder>",
            wordsEmittedIn5s: -1,
            detectedLang: "placeholder",
            confidenceCorrect: 0,
            confidenceWrong: 0,
            correctDetection: false,
            timeToDecisionS: 0
        )
        print(placeholder.csvRow)
    }

    // MARK: - Evaluate C

    private static func runEvaluateC(args: [String]) async throws {
        if args.contains("--header") {
            print(OptionCResult.csvHeader)
            return
        }

        let clipPath = try parseRequiredArg("--clip", from: args)
        let pair = try parseRequiredArg("--pair", from: args)
        let windowStr = try parseRequiredArg("--window", from: args)
        let manifestPath = try parseRequiredArg("--manifest", from: args)

        guard let windowS = Double(windowStr), (windowS == 3.0 || windowS == 5.0) else {
            fputs("Error: --window must be 3 or 5\n", stderr)
            throw ExitError.invalidArgument
        }

        let manifest = try ClipManifest.load(from: URL(fileURLWithPath: manifestPath))
        let clipFilename = URL(fileURLWithPath: clipPath).lastPathComponent

        guard let clipEntry = manifest.clips.first(where: { $0.filename == clipFilename }) else {
            fputs("Error: clip '\(clipFilename)' not found in manifest\n", stderr)
            throw ExitError.clipNotInManifest
        }

        logger.info(
            "evaluate-c: clip=\(clipFilename) pair=\(pair) window=\(windowStr)s ground_truth=\(clipEntry.language)"
        )

        // --- Phase C placeholder ---
        fputs(
            "evaluate-c: NOT YET IMPLEMENTED — Phase C adds LID model inference\n",
            stderr
        )
        fputs(
            "  Would evaluate: \(clipFilename) with \(windowStr)s window, "
            + "detect among [\(pair)]\n",
            stderr
        )

        let placeholder = OptionCResult(
            clip: clipFilename,
            pair: pair,
            groundTruthLang: clipEntry.language,
            declaredPair: pair,
            windowS: windowS,
            detectedLang: "placeholder",
            confidenceCorrect: 0,
            confidenceWrong: 0,
            correctDetection: false,
            inferenceTimeMs: 0,
            modelName: "none",
            modelSizeMb: 0
        )
        print(placeholder.csvRow)
    }

    // MARK: - Analyze Wordcount

    private static func runAnalyzeWordcount(args: [String]) throws {
        let csvPath = try parseRequiredArg("--csv", from: args)
        let csvURL = URL(fileURLWithPath: csvPath)
        let csvString = try String(contentsOf: csvURL, encoding: .utf8)
        let lines = csvString.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }

        guard lines.count > 1 else {
            print("No data rows in CSV.")
            return
        }

        print("Word-Count Threshold Analysis")
        print("=============================")
        print("")

        let headerColumns = lines[0].split(separator: ",").map(String.init)
        guard let pairIdx = headerColumns.firstIndex(of: "pair"),
              let guessIdx = headerColumns.firstIndex(of: "guess_mode"),
              let wordsIdx = headerColumns.firstIndex(of: "words_emitted_in_5s")
        else {
            fputs("Error: CSV missing required columns (pair, guess_mode, words_emitted_in_5s)\n", stderr)
            throw ExitError.invalidCSV
        }

        let dataRows = lines.dropFirst().compactMap { line -> (pair: String, guessMode: String, words: Int)? in
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard cols.count > max(pairIdx, guessIdx, wordsIdx),
                  let words = Int(cols[wordsIdx])
            else { return nil }
            return (pair: cols[pairIdx], guessMode: cols[guessIdx], words: words)
        }

        let pairs = Set(dataRows.map(\.pair)).sorted()

        for pair in pairs {
            let pairRows = dataRows.filter { $0.pair == pair }
            let correctCounts = pairRows.filter { $0.guessMode == "correct" }.map(\.words)
            let wrongCounts = pairRows.filter { $0.guessMode == "wrong" }.map(\.words)

            print("Pair: \(pair)")
            print("  Correct-guess word counts: \(correctCounts.sorted())")
            print("  Wrong-guess word counts:   \(wrongCounts.sorted())")

            if let result = ThresholdAnalyzer.findOptimalThreshold(
                correctGuessWordCounts: correctCounts,
                wrongGuessWordCounts: wrongCounts
            ) {
                print("  Optimal threshold: \(result.threshold) words")
                print("  Accuracy: \(String(format: "%.1f", result.accuracy * 100))%")
                print("  TP=\(result.truePositives) FP=\(result.falsePositives) "
                      + "TN=\(result.trueNegatives) FN=\(result.falseNegatives)")
                let separation = correctCounts.isEmpty || wrongCounts.isEmpty
                    ? "N/A"
                    : String(format: "%.1fx",
                             Double(correctCounts.reduce(0, +)) / Double(max(1, correctCounts.count))
                             / Double(max(1, wrongCounts.reduce(0, +) / max(1, wrongCounts.count))))
                print("  Mean word-count ratio (correct/wrong): \(separation)")
            } else {
                print("  No data for threshold analysis.")
            }
            print("")
        }
    }

    // MARK: - Argument Parsing

    private static func parseRequiredArg(
        _ flag: String,
        from args: [String]
    ) throws -> String {
        guard let idx = args.firstIndex(of: flag),
              idx + 1 < args.count
        else {
            fputs("Error: missing required argument '\(flag)'\n", stderr)
            throw ExitError.missingArgument
        }
        return args[idx + 1]
    }

    // MARK: - Usage

    private static func printUsage() {
        let usage = """
            USAGE: LangDetectSpikeCLI <subcommand> [options]

            SUBCOMMANDS:
              preflight           Verify corpus, locale models, and NLLanguageRecognizer
              evaluate-b          Run Option B evaluation on a single clip
              evaluate-c          Run Option C evaluation on a single clip
              analyze-wordcount   Analyze word-count signal from Option B CSV

            PREFLIGHT:
              --manifest <path>   Path to recordings/manifest.json

            EVALUATE-B:
              --clip <path>       Path to audio file (.caf)
              --pair <pair>       Language pair (e.g., en+ru)
              --guess-mode <mode> 'wrong' or 'correct'
              --manifest <path>   Path to recordings/manifest.json
              --header            Print CSV header only (no evaluation)

            EVALUATE-C:
              --clip <path>       Path to audio file (.caf)
              --pair <pair>       Language pair (e.g., en+ru)
              --window <seconds>  Audio window: 3 or 5
              --manifest <path>   Path to recordings/manifest.json
              --header            Print CSV header only (no evaluation)

            ANALYZE-WORDCOUNT:
              --csv <path>        Path to Option B results CSV
            """
        print(usage)
    }
}

enum ExitError: Error {
    case unknownSubcommand
    case missingArgument
    case invalidArgument
    case clipNotInManifest
    case invalidCSV
}
