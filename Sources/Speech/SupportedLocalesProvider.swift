import Foundation
import Speech

// MARK: - SupportedLocalesProvider

nonisolated protocol SupportedLocalesProvider: Sendable {
    func supportedLocales() async -> [Locale]
}

// MARK: - SystemSupportedLocalesProvider

nonisolated struct SystemSupportedLocalesProvider: SupportedLocalesProvider {
    func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }
}

// MARK: - Locale matching

/// Matches a candidate Apple locale against a desired locale.
/// If the desired locale has no region, accepts any matching language code.
/// Prevents the en vs en-US mismatch that caused Session 006 bugs.
nonisolated func localeMatches(_ candidate: Locale, _ desired: Locale) -> Bool {
    let candidateLang = candidate.language.languageCode?.identifier ?? ""
    let desiredLang = desired.language.languageCode?.identifier ?? ""
    guard candidateLang == desiredLang else { return false }

    let desiredRegion = desired.language.region?.identifier ?? ""
    if desiredRegion.isEmpty { return true }

    let candidateRegion = candidate.language.region?.identifier ?? ""
    return candidateRegion == desiredRegion
}
