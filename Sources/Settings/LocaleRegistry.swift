import Foundation

enum LocaleRegistry: Sendable {

    enum Backend: String, Sendable {
        case apple
        case parakeet
    }

    struct Entry: Sendable, Identifiable {
        let identifier: String
        let displayName: String
        let backend: Backend
        nonisolated var id: String { identifier }
    }

    // Sorted alphabetically by displayName (case-insensitive).
    // Apple-backed: 27 locales from SpeechTranscriber.supportedLocales on macOS 26.
    // Parakeet-backed: 23 additional European locales from Parakeet v3.
    // Apple preferred when both backends cover a locale.
    // Update path: edit this array when Apple/Parakeet add locales. M3.4 adds runtime assertion.
    nonisolated(unsafe) static let allLocales: [Entry] = [
        Entry(identifier: "sq_AL", displayName: "Albanian", backend: .parakeet),
        Entry(identifier: "ar_SA", displayName: "Arabic (Saudi Arabia)", backend: .apple),
        Entry(identifier: "eu_ES", displayName: "Basque", backend: .parakeet),
        Entry(identifier: "bg_BG", displayName: "Bulgarian", backend: .parakeet),
        Entry(identifier: "ca_ES", displayName: "Catalan", backend: .parakeet),
        Entry(identifier: "zh_CN", displayName: "Chinese (Simplified)", backend: .apple),
        Entry(identifier: "zh_TW", displayName: "Chinese (Traditional)", backend: .apple),
        Entry(identifier: "hr_HR", displayName: "Croatian", backend: .parakeet),
        Entry(identifier: "cs_CZ", displayName: "Czech", backend: .parakeet),
        Entry(identifier: "da_DK", displayName: "Danish", backend: .parakeet),
        Entry(identifier: "nl_NL", displayName: "Dutch (Netherlands)", backend: .apple),
        Entry(identifier: "en_AU", displayName: "English (Australia)", backend: .apple),
        Entry(identifier: "en_CA", displayName: "English (Canada)", backend: .apple),
        Entry(identifier: "en_IN", displayName: "English (India)", backend: .apple),
        Entry(identifier: "en_IE", displayName: "English (Ireland)", backend: .apple),
        Entry(identifier: "en_NZ", displayName: "English (New Zealand)", backend: .apple),
        Entry(identifier: "en_SG", displayName: "English (Singapore)", backend: .apple),
        Entry(identifier: "en_ZA", displayName: "English (South Africa)", backend: .apple),
        Entry(identifier: "en_GB", displayName: "English (United Kingdom)", backend: .apple),
        Entry(identifier: "en_US", displayName: "English (United States)", backend: .apple),
        Entry(identifier: "et_EE", displayName: "Estonian", backend: .parakeet),
        Entry(identifier: "fi_FI", displayName: "Finnish", backend: .parakeet),
        Entry(identifier: "fr_CA", displayName: "French (Canada)", backend: .apple),
        Entry(identifier: "fr_FR", displayName: "French (France)", backend: .apple),
        Entry(identifier: "gl_ES", displayName: "Galician", backend: .parakeet),
        Entry(identifier: "de_DE", displayName: "German (Germany)", backend: .apple),
        Entry(identifier: "el_GR", displayName: "Greek", backend: .parakeet),
        Entry(identifier: "hi_IN", displayName: "Hindi (India)", backend: .apple),
        Entry(identifier: "hu_HU", displayName: "Hungarian", backend: .parakeet),
        Entry(identifier: "it_IT", displayName: "Italian (Italy)", backend: .apple),
        Entry(identifier: "ja_JP", displayName: "Japanese (Japan)", backend: .apple),
        Entry(identifier: "ko_KR", displayName: "Korean (South Korea)", backend: .apple),
        Entry(identifier: "lv_LV", displayName: "Latvian", backend: .parakeet),
        Entry(identifier: "lt_LT", displayName: "Lithuanian", backend: .parakeet),
        Entry(identifier: "mk_MK", displayName: "Macedonian", backend: .parakeet),
        Entry(identifier: "nb_NO", displayName: "Norwegian Bokmål", backend: .parakeet),
        Entry(identifier: "pl_PL", displayName: "Polish (Poland)", backend: .apple),
        Entry(identifier: "pt_BR", displayName: "Portuguese (Brazil)", backend: .apple),
        Entry(identifier: "pt_PT", displayName: "Portuguese (Portugal)", backend: .apple),
        Entry(identifier: "ro_RO", displayName: "Romanian", backend: .parakeet),
        Entry(identifier: "ru_RU", displayName: "Russian", backend: .parakeet),
        Entry(identifier: "sk_SK", displayName: "Slovak", backend: .parakeet),
        Entry(identifier: "sl_SI", displayName: "Slovenian", backend: .parakeet),
        Entry(identifier: "es_MX", displayName: "Spanish (Mexico)", backend: .apple),
        Entry(identifier: "es_ES", displayName: "Spanish (Spain)", backend: .apple),
        Entry(identifier: "sv_SE", displayName: "Swedish", backend: .parakeet),
        Entry(identifier: "th_TH", displayName: "Thai (Thailand)", backend: .apple),
        Entry(identifier: "tr_TR", displayName: "Turkish (Türkiye)", backend: .apple),
        Entry(identifier: "uk_UA", displayName: "Ukrainian", backend: .parakeet),
        Entry(identifier: "cy_GB", displayName: "Welsh", backend: .parakeet),
    ]
}
