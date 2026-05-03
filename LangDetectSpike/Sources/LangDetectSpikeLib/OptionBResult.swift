public struct OptionBResult: Sendable, Equatable {
    public let clip: String
    public let pair: String
    public let groundTruthLang: String
    public let initializedLang: String
    public let guessMode: GuessMode
    public let partialText: String
    public let wordsEmittedIn5s: Int
    public let detectedLang: String
    public let confidenceCorrect: Double
    public let confidenceWrong: Double
    public let correctDetection: Bool
    public let timeToDecisionS: Double

    public enum GuessMode: String, Sendable {
        case wrong
        case correct
    }

    public init(
        clip: String,
        pair: String,
        groundTruthLang: String,
        initializedLang: String,
        guessMode: GuessMode,
        partialText: String,
        wordsEmittedIn5s: Int,
        detectedLang: String,
        confidenceCorrect: Double,
        confidenceWrong: Double,
        correctDetection: Bool,
        timeToDecisionS: Double
    ) {
        self.clip = clip
        self.pair = pair
        self.groundTruthLang = groundTruthLang
        self.initializedLang = initializedLang
        self.guessMode = guessMode
        self.partialText = partialText
        self.wordsEmittedIn5s = wordsEmittedIn5s
        self.detectedLang = detectedLang
        self.confidenceCorrect = confidenceCorrect
        self.confidenceWrong = confidenceWrong
        self.correctDetection = correctDetection
        self.timeToDecisionS = timeToDecisionS
    }

    public static var csvHeader: String {
        [
            "clip", "pair", "ground_truth_lang", "initialized_lang",
            "guess_mode", "partial_text", "words_emitted_in_5s",
            "detected_lang", "confidence_correct", "confidence_wrong",
            "correct_detection", "time_to_decision_s",
        ].joined(separator: ",")
    }

    public var csvRow: String {
        let escapedText = partialText
            .replacingOccurrences(of: "\"", with: "\"\"")
        return [
            clip,
            pair,
            groundTruthLang,
            initializedLang,
            guessMode.rawValue,
            "\"\(escapedText)\"",
            "\(wordsEmittedIn5s)",
            detectedLang,
            String(format: "%.4f", confidenceCorrect),
            String(format: "%.4f", confidenceWrong),
            correctDetection ? "true" : "false",
            String(format: "%.3f", timeToDecisionS),
        ].joined(separator: ",")
    }
}
