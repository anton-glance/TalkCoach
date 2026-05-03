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
        self.clip = clip
        self.pair = pair
        self.groundTruthLang = groundTruthLang
        self.declaredPair = declaredPair
        self.windowS = windowS
        self.detectedLang = detectedLang
        self.confidenceCorrect = confidenceCorrect
        self.confidenceWrong = confidenceWrong
        self.correctDetection = correctDetection
        self.inferenceTimeMs = inferenceTimeMs
        self.modelName = modelName
        self.modelSizeMb = modelSizeMb
    }

    public static var csvHeader: String {
        [
            "clip", "pair", "ground_truth_lang", "declared_pair",
            "window_s", "detected_lang", "confidence_correct",
            "confidence_wrong", "correct_detection", "inference_time_ms",
            "model_name", "model_size_mb",
        ].joined(separator: ",")
    }

    public var csvRow: String {
        [
            clip,
            pair,
            groundTruthLang,
            declaredPair,
            String(format: "%.1f", windowS),
            detectedLang,
            String(format: "%.4f", confidenceCorrect),
            String(format: "%.4f", confidenceWrong),
            correctDetection ? "true" : "false",
            String(format: "%.1f", inferenceTimeMs),
            modelName,
            String(format: "%.1f", modelSizeMb),
        ].joined(separator: ",")
    }
}
