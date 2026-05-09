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
    .other
}
