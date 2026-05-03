import AVFoundation
import FluidAudio
import Foundation
import LangDetectSpikeLib
import NaturalLanguage
import os
import Speech

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
        try await runSpeechTranscriberLocaleCheck()
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
        let testCases: [(label: String, expected: NLLanguage, sentence: String)] = [
            ("en", .english,
             "The quick brown fox jumps over the lazy dog and runs through the forest meadow"),
            ("ru", .russian,
             "Быстрая коричневая лиса прыгает через ленивую собаку и бежит через лес"),
            ("ja", .japanese,
             "速い茶色の狐が怠惰な犬を飛び越えて森を走り抜けます"),
            ("es", .spanish,
             "El rápido zorro marrón salta sobre el perro perezoso y corre por el bosque"),
        ]

        var allPassed = true
        let recognizer = NLLanguageRecognizer()

        for (label, expected, sentence) in testCases {
            recognizer.reset()
            recognizer.processString(sentence)
            let detected = recognizer.dominantLanguage
            let passed = detected == expected
            if !passed { allPassed = false }

            let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
            let hypoStr = hypotheses
                .sorted { $0.value > $1.value }
                .map { "\($0.key.rawValue):\(String(format: "%.2f", $0.value))" }
                .joined(separator: " ")

            print("  \(label): detected=\(detected?.rawValue ?? "nil") — \(passed ? "PASS" : "FAIL") [\(hypoStr)]")
        }

        if !allPassed {
            throw ExitError.preflightFailed
        }
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

    private static func runSpeechTranscriberLocaleCheck() async throws {
        let testLocales: [(label: String, locale: Locale)] = [
            ("en_US", Locale(identifier: "en-US")),
            ("ja_JP", Locale(identifier: "ja-JP")),
            ("es_ES", Locale(identifier: "es-ES")),
        ]

        var allPassed = true

        for (label, locale) in testLocales {
            print("  \(label):")
            do {
                guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                    print("    NOT SUPPORTED — locale not available on this device")
                    allPassed = false
                    continue
                }
                print("    Supported (resolved: \(resolved.identifier))")

                let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)

                let status = await AssetInventory.status(forModules: [transcriber])
                print("    Asset status: \(assetStatusString(status))")

                if status != .installed {
                    print("    Downloading model (may take a few minutes)...")
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                        try await request.downloadAndInstall()
                    }
                    let newStatus = await AssetInventory.status(forModules: [transcriber])
                    print("    Post-download status: \(assetStatusString(newStatus))")
                    if newStatus != .installed {
                        print("    FAIL — model not installed after download attempt")
                        allPassed = false
                        continue
                    }
                }

                let sampleRate = 16000.0
                guard let format = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: sampleRate,
                    channels: 1,
                    interleaved: true
                ) else {
                    print("    FAIL — could not create audio format")
                    allPassed = false
                    continue
                }
                let frameCount = AVAudioFrameCount(sampleRate)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: frameCount
                ) else {
                    print("    FAIL — could not create audio buffer")
                    allPassed = false
                    continue
                }
                buffer.frameLength = frameCount

                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let (inputStream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
                continuation.yield(AnalyzerInput(buffer: buffer))
                continuation.finish()

                let lastTime = try await analyzer.analyzeSequence(inputStream)
                if let lastTime {
                    try await analyzer.finalizeAndFinish(through: lastTime)
                } else {
                    await analyzer.cancelAndFinishNow()
                }

                print("    Pipeline test: PASS (analyzer processed 1s silence without error)")
            } catch {
                print("    ERROR: \(error)")
                allPassed = false
            }
        }

        if !allPassed {
            throw ExitError.preflightFailed
        }
    }

    private static func assetStatusString(_ status: AssetInventory.Status) -> String {
        switch status {
        case .installed: "installed"
        case .supported: "supported (needs download)"
        case .downloading: "downloading"
        case .unsupported: "unsupported"
        @unknown default: "unknown"
        }
    }

    // MARK: - Evaluate B

    private static let langToLocaleID: [String: String] = [
        "en": "en-US", "ja": "ja-JP", "es": "es-ES", "ru": "ru-RU",
    ]

    private static let parakeetOnlyLanguages: Set<String> = ["ru"]

    private static func parakeetLanguage(for langCode: String) -> Language? {
        switch langCode {
        case "ru": .russian
        default: nil
        }
    }

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

        let otherLang = (groundTruth == pairParts[0]) ? pairParts[1] : pairParts[0]

        logger.info(
            "evaluate-b: clip=\(clipFilename) pair=\(pair) guess=\(guessModeStr) ground_truth=\(groundTruth) initialized=\(initializedLang)"
        )

        let clipURL = URL(fileURLWithPath: clipPath)
        let useParakeet = parakeetOnlyLanguages.contains(initializedLang)

        let fullText: String
        let elapsedS: Double

        if useParakeet {
            logger.info("Routing \(initializedLang) through Parakeet (FluidAudio)")
            let startTime = ContinuousClock.now

            let models = try await AsrModels.downloadAndLoad(version: .v3)
            logger.info("Parakeet model loaded")

            let asrManager = AsrManager(models: models)
            let parakeetLang = parakeetLanguage(for: initializedLang)
            var decoderState = try TdtDecoderState()
            let asrResult = try await asrManager.transcribe(
                clipURL, decoderState: &decoderState, language: parakeetLang
            )

            let elapsed = ContinuousClock.now - startTime
            elapsedS = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            fullText = asrResult.text
        } else {
            guard let localeID = langToLocaleID[initializedLang] else {
                fputs("Error: no locale mapping for '\(initializedLang)'\n", stderr)
                throw ExitError.invalidArgument
            }

            let locale = Locale(identifier: localeID)
            guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                logger.warning("Locale \(localeID) not supported by SpeechTranscriber — emitting UNSUPPORTED row")
                let result = OptionBResult(
                    clip: clipFilename, pair: pair,
                    groundTruthLang: groundTruth, initializedLang: initializedLang,
                    guessMode: guessMode, partialText: "UNSUPPORTED_LOCALE",
                    wordsEmittedIn5s: -1, detectedLang: "unsupported",
                    confidenceCorrect: 0, confidenceWrong: 0,
                    correctDetection: false, timeToDecisionS: 0
                )
                print(result.csvRow)
                return
            }

            let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)

            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    logger.info("Downloading model for \(resolved.identifier)...")
                    try await request.downloadAndInstall()
                }
            } catch {
                logger.warning("Model for \(resolved.identifier) unavailable: \(error.localizedDescription)")
                let result = OptionBResult(
                    clip: clipFilename, pair: pair,
                    groundTruthLang: groundTruth, initializedLang: initializedLang,
                    guessMode: guessMode, partialText: "UNSUPPORTED_LOCALE",
                    wordsEmittedIn5s: -1, detectedLang: "unsupported",
                    confidenceCorrect: 0, confidenceWrong: 0,
                    correctDetection: false, timeToDecisionS: 0
                )
                print(result.csvRow)
                return
            }

            let audioFile = try AVAudioFile(forReading: clipURL)
            let startTime = ContinuousClock.now

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)

            var phrases: [String] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if !text.isEmpty {
                    phrases.append(text)
                }
            }

            let elapsed = ContinuousClock.now - startTime
            elapsedS = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            fullText = phrases.joined(separator: " ")
        }
        let wordCount = WordCounter.countWords(in: fullText)

        let detection = NLDetection.detect(
            text: fullText,
            groundTruthLang: groundTruth,
            otherLang: otherLang
        )

        logger.info(
            "evaluate-b result: words=\(wordCount) detected=\(detection.detectedLang) correct=\(detection.correctDetection) elapsed=\(String(format: "%.2f", elapsedS))s"
        )

        let result = OptionBResult(
            clip: clipFilename, pair: pair,
            groundTruthLang: groundTruth, initializedLang: initializedLang,
            guessMode: guessMode, partialText: fullText,
            wordsEmittedIn5s: wordCount, detectedLang: detection.detectedLang,
            confidenceCorrect: detection.confidenceGroundTruth,
            confidenceWrong: detection.confidenceOther,
            correctDetection: detection.correctDetection,
            timeToDecisionS: elapsedS
        )
        print(result.csvRow)
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
              let wordsIdx = headerColumns.firstIndex(of: "words_emitted_in_5s"),
              let textIdx = headerColumns.firstIndex(of: "partial_text")
        else {
            fputs("Error: CSV missing required columns (pair, guess_mode, words_emitted_in_5s, partial_text)\n", stderr)
            throw ExitError.invalidCSV
        }

        let dataRows = lines.dropFirst().compactMap { line -> (pair: String, guessMode: String, words: Int, charCount: Int)? in
            let cols = parseCSVLine(line)
            guard cols.count > max(pairIdx, guessIdx, wordsIdx, textIdx),
                  let words = Int(cols[wordsIdx])
            else { return nil }
            let text = cols[textIdx]
            let charCount = text.count
            return (pair: cols[pairIdx], guessMode: cols[guessIdx], words: words, charCount: charCount)
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

        print("")
        print("Character-Count Analysis")
        print("========================")
        print("")

        for pair in pairs {
            let pairRows = dataRows.filter { $0.pair == pair }
            let correctChars = pairRows.filter { $0.guessMode == "correct" }.map(\.charCount)
            let wrongChars = pairRows.filter { $0.guessMode == "wrong" }.map(\.charCount)

            print("Pair: \(pair)")
            print("  Correct-guess char counts: \(correctChars.sorted())")
            print("  Wrong-guess char counts:   \(wrongChars.sorted())")

            if let result = ThresholdAnalyzer.findOptimalThreshold(
                correctGuessWordCounts: correctChars,
                wrongGuessWordCounts: wrongChars
            ) {
                print("  Optimal threshold: \(result.threshold) chars")
                print("  Accuracy: \(String(format: "%.1f", result.accuracy * 100))%")
                print("  TP=\(result.truePositives) FP=\(result.falsePositives) "
                      + "TN=\(result.trueNegatives) FN=\(result.falseNegatives)")
                let separation = correctChars.isEmpty || wrongChars.isEmpty
                    ? "N/A"
                    : String(format: "%.1fx",
                             Double(correctChars.reduce(0, +)) / Double(max(1, correctChars.count))
                             / Double(max(1, wrongChars.reduce(0, +) / max(1, wrongChars.count))))
                print("  Mean char-count ratio (correct/wrong): \(separation)")
            } else {
                print("  No data for threshold analysis.")
            }
            print("")
        }
    }

    // MARK: - CSV Parsing

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var chars = line.makeIterator()

        while let ch = chars.next() {
            if inQuotes {
                if ch == "\"" {
                    if let next = chars.next() {
                        if next == "\"" {
                            current.append("\"")
                        } else {
                            inQuotes = false
                            if next == "," {
                                fields.append(current)
                                current = ""
                            } else {
                                current.append(next)
                            }
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" {
                inQuotes = true
            } else if ch == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        return fields
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
    case preflightFailed
}
