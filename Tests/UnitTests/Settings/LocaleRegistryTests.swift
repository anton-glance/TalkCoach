import XCTest
@testable import TalkCoach

@MainActor
final class LocaleRegistryTests: XCTestCase {

    func testRegistryContainsAtLeast50Locales() {
        XCTAssertGreaterThanOrEqual(LocaleRegistry.allLocales.count, 50)
    }

    func testRegistryContainsAppleLocales() {
        let identifiers = Set(LocaleRegistry.allLocales.map(\.identifier))
        let expectedApple = ["en_US", "es_ES", "fr_FR", "ja_JP", "zh_CN"]
        for locale in expectedApple {
            XCTAssertTrue(identifiers.contains(locale), "\(locale) should be in the registry")
            let entry = LocaleRegistry.allLocales.first { $0.identifier == locale }
            XCTAssertEqual(entry?.backend, .apple, "\(locale) should have .apple backend")
        }
    }

    func testRegistryContainsParakeetLocales() {
        let entry = LocaleRegistry.allLocales.first { $0.identifier == "ru_RU" }
        XCTAssertNotNil(entry, "ru_RU must be in the registry")
        XCTAssertEqual(entry?.backend, .parakeet, "ru_RU must have .parakeet backend")
    }

    func testRegistryAlphabetizedDisplayNames() {
        let names = LocaleRegistry.allLocales.map(\.displayName)
        let sorted = names.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
        XCTAssertEqual(names, sorted, "allLocales must be sorted by displayName")
    }

    func testRegistryHasNoDuplicateIdentifiers() {
        let identifiers = LocaleRegistry.allLocales.map(\.identifier)
        let uniqueCount = Set(identifiers).count
        XCTAssertEqual(identifiers.count, uniqueCount, "No duplicate identifiers allowed")
    }
}
