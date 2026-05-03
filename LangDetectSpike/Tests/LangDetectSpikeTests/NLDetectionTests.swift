import NaturalLanguage
import Testing
@testable import LangDetectSpikeLib

struct NLDetectionTests {

    // MARK: - Language code mapping

    @Test func langCodeToNLLanguageMapsKnownCodes() {
        #expect(NLDetection.langCodeToNLLanguage("en") == .english)
        #expect(NLDetection.langCodeToNLLanguage("ru") == .russian)
        #expect(NLDetection.langCodeToNLLanguage("ja") == .japanese)
        #expect(NLDetection.langCodeToNLLanguage("es") == .spanish)
    }

    @Test func langCodeToNLLanguageReturnsNilForUnknown() {
        #expect(NLDetection.langCodeToNLLanguage("xx") == nil)
        #expect(NLDetection.langCodeToNLLanguage("") == nil)
    }

    // MARK: - Constrained detection on clean text

    @Test func detectsEnglishConstrainedToEnRu() {
        let result = NLDetection.detect(
            text: "The quick brown fox jumps over the lazy dog and runs through the forest",
            groundTruthLang: "en",
            otherLang: "ru"
        )
        #expect(result.detectedLang == "en")
        #expect(result.correctDetection == true)
        #expect(result.confidenceGroundTruth > 0.5)
    }

    @Test func detectsRussianConstrainedToEnRu() {
        let result = NLDetection.detect(
            text: "Быстрая коричневая лиса прыгает через ленивую собаку и бежит через лес",
            groundTruthLang: "ru",
            otherLang: "en"
        )
        #expect(result.detectedLang == "ru")
        #expect(result.correctDetection == true)
        #expect(result.confidenceGroundTruth > 0.5)
    }

    @Test func detectsJapaneseConstrainedToEnJa() {
        let result = NLDetection.detect(
            text: "速い茶色の狐が怠惰な犬を飛び越えて森を走り抜けます",
            groundTruthLang: "ja",
            otherLang: "en"
        )
        #expect(result.detectedLang == "ja")
        #expect(result.correctDetection == true)
    }

    @Test func detectsSpanishConstrainedToEnEs() {
        let result = NLDetection.detect(
            text: "El rápido zorro marrón salta sobre el perro perezoso y corre por el bosque",
            groundTruthLang: "es",
            otherLang: "en"
        )
        #expect(result.detectedLang == "es")
        #expect(result.correctDetection == true)
    }

    // MARK: - Edge cases

    @Test func emptyTextReturnsUndetermined() {
        let result = NLDetection.detect(
            text: "",
            groundTruthLang: "en",
            otherLang: "ru"
        )
        #expect(result.detectedLang == "undetermined")
        #expect(result.correctDetection == false)
    }

    @Test func confidenceSumsCloseToOneForCleanText() {
        let result = NLDetection.detect(
            text: "This is a clear English sentence that should be easy to identify correctly",
            groundTruthLang: "en",
            otherLang: "es"
        )
        let sum = result.confidenceGroundTruth + result.confidenceOther
        #expect(sum > 0.9)
        #expect(sum <= 1.01)
    }

    @Test func detectionWithConstraintsUsesOnlyPairLanguages() {
        // Portuguese text constrained to en+es should pick Spanish (closest),
        // not Portuguese — verifying constraints are applied.
        let result = NLDetection.detect(
            text: "O rápido raposa marrom pula sobre o cachorro preguiçoso e corre pela floresta",
            groundTruthLang: "es",
            otherLang: "en"
        )
        // NLLanguageRecognizer constrained to [en, es] must pick one of the two.
        // Portuguese is closer to Spanish, so we expect "es".
        #expect(result.detectedLang == "en" || result.detectedLang == "es")
    }
}
