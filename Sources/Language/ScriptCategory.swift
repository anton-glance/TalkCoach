import Foundation

nonisolated enum ScriptCategory: Sendable, Equatable {
    case latin
    case cyrillic
    case cjk
    case arabic
    case devanagari
    case other

    var isCJK: Bool { self == .cjk }
}

nonisolated func dominantScript(for locale: Locale) -> ScriptCategory {
    let langCode = locale.language.languageCode?.identifier ?? ""
    let scriptID = Locale.Language(identifier: langCode).script?.identifier

    switch scriptID {
    case "Latn":
        return .latin
    case "Cyrl":
        return .cyrillic
    case "Jpan", "Kore", "Hans", "Hant":
        return .cjk
    case "Arab", "Aran":
        return .arabic
    case "Deva":
        return .devanagari
    default:
        return .other
    }
}
