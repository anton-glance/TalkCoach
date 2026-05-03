public struct LanguagePair: Sendable, Equatable {
    public let lang1: String
    public let lang2: String

    public var label: String { "\(lang1)+\(lang2)" }

    public init(lang1: String, lang2: String) {
        self.lang1 = lang1
        self.lang2 = lang2
    }

    public static let enRu = LanguagePair(lang1: "en", lang2: "ru")
    public static let enJa = LanguagePair(lang1: "en", lang2: "ja")
    public static let enEs = LanguagePair(lang1: "en", lang2: "es")

    public static let all: [LanguagePair] = [.enRu, .enJa, .enEs]
}
