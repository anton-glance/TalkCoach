public struct OptionCResult: Sendable, Equatable {
    public let clip: String
    public let pair: String
    public let groundTruthLang: String
    public let declaredPair: String
    public let windowS: Double
    public let detectedLang: String
    public let confidenceCorrect: Double
    public let confidenceWrong: Double
    public let correctDetection: Bool
    public let inferenceTimeMs: Double
    public let modelName: String
    public let modelSizeMb: Double

    public init(
        clip: String,
        pair: String,
        groundTruthLang: String,
        declaredPair: String,
        windowS: Double,
        detectedLang: String,
        confidenceCorrect: Double,
        confidenceWrong: Double,
        correctDetection: Bool,
        inferenceTimeMs: Double,
        modelName: String,
        modelSizeMb: Double
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
