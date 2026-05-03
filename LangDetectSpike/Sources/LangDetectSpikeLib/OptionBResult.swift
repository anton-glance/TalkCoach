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
        fatalError("Not implemented — red phase stub")
    }

    public static var csvHeader: String {
        fatalError("Not implemented — red phase stub")
    }

    public var csvRow: String {
        fatalError("Not implemented — red phase stub")
    }
}
