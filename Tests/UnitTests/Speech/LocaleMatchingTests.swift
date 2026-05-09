import XCTest
@testable import TalkCoach

@MainActor
final class LocaleMatchingTests: XCTestCase {

    // MARK: Exact match

    func testExactMatchReturnsTrue() {
        XCTAssertTrue(localeMatches(Locale(identifier: "en-US"), Locale(identifier: "en-US")))
    }

    // MARK: Language-only desired (no region) — accepts any region on candidate

    func testLanguageOnlyDesiredMatchesAnyRegion() {
        XCTAssertTrue(localeMatches(Locale(identifier: "en-US"), Locale(identifier: "en")))
    }

    func testRussianNoRegionMatchesRuRU() {
        XCTAssertTrue(localeMatches(Locale(identifier: "ru-RU"), Locale(identifier: "ru")))
    }

    func testBothNoRegionSameLanguageReturnsTrue() {
        XCTAssertTrue(localeMatches(Locale(identifier: "en"), Locale(identifier: "en")))
    }

    // MARK: Mismatches

    func testRegionMismatchReturnsFalse() {
        XCTAssertFalse(localeMatches(Locale(identifier: "en-US"), Locale(identifier: "en-GB")))
    }

    func testLanguageMismatchReturnsFalse() {
        XCTAssertFalse(localeMatches(Locale(identifier: "fr-FR"), Locale(identifier: "en-US")))
    }

    func testNoRegionDesiredDifferentLanguageReturnsFalse() {
        XCTAssertFalse(localeMatches(Locale(identifier: "en-US"), Locale(identifier: "ru")))
    }
}
