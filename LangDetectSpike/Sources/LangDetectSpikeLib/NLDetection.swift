import Foundation
import NaturalLanguage

public struct NLDetectionResult: Sendable, Equatable {
    public let detectedLang: String
    public let confidenceGroundTruth: Double
    public let confidenceOther: Double
    public let correctDetection: Bool

    public init(
        detectedLang: String,
        confidenceGroundTruth: Double,
        confidenceOther: Double,
        correctDetection: Bool
    ) {
        self.detectedLang = detectedLang
        self.confidenceGroundTruth = confidenceGroundTruth
        self.confidenceOther = confidenceOther
        self.correctDetection = correctDetection
    }
}

public struct NLDetection: Sendable {

    private static let knownLanguages: [String: NLLanguage] = [
        "en": .english,
        "ru": .russian,
        "ja": .japanese,
        "es": .spanish,
        "fr": .french,
        "de": .german,
        "it": .italian,
        "pt": .portuguese,
        "ko": .korean,
        "zh": .simplifiedChinese,
        "uk": .ukrainian,
        "pl": .polish,
    ]

    public static func langCodeToNLLanguage(_ code: String) -> NLLanguage? {
        knownLanguages[code]
    }

    public static func detect(
        text: String,
        groundTruthLang: String,
        otherLang: String
    ) -> NLDetectionResult {
        guard !text.isEmpty else {
            return NLDetectionResult(
                detectedLang: "undetermined",
                confidenceGroundTruth: 0,
                confidenceOther: 0,
                correctDetection: false
            )
        }

        let recognizer = NLLanguageRecognizer()

        if let gtNL = langCodeToNLLanguage(groundTruthLang),
           let otherNL = langCodeToNLLanguage(otherLang) {
            recognizer.languageConstraints = [gtNL, otherNL]
        }

        recognizer.processString(text)

        let detected = recognizer.dominantLanguage
        let detectedRaw = detected?.rawValue ?? "undetermined"

        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)

        let gtNL = langCodeToNLLanguage(groundTruthLang)
        let otherNL = langCodeToNLLanguage(otherLang)

        let confidenceGT = gtNL.flatMap { hypotheses[$0] } ?? 0
        let confidenceOther = otherNL.flatMap { hypotheses[$0] } ?? 0

        return NLDetectionResult(
            detectedLang: detectedRaw,
            confidenceGroundTruth: confidenceGT,
            confidenceOther: confidenceOther,
            correctDetection: detectedRaw == groundTruthLang
        )
    }
}
