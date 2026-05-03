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

    public static func langCodeToNLLanguage(_ code: String) -> NLLanguage? {
        nil
    }

    public static func detect(
        text: String,
        groundTruthLang: String,
        otherLang: String
    ) -> NLDetectionResult {
        NLDetectionResult(
            detectedLang: "",
            confidenceGroundTruth: 0,
            confidenceOther: 0,
            correctDetection: false
        )
    }
}
