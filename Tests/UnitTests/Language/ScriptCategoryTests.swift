import XCTest
@testable import TalkCoach

final class ScriptCategoryTests: XCTestCase {

    // MARK: - Latin script

    func testEnglishMapsToLatin() {
        XCTAssertEqual(dominantScript(for: Locale(identifier: "en_US")), .latin)
    }

    func testSpanishMapsToLatin() {
        XCTAssertEqual(dominantScript(for: Locale(identifier: "es_ES")), .latin)
    }

    func testFrenchMapsToLatin() {
        XCTAssertEqual(dominantScript(for: Locale(identifier: "fr_FR")), .latin)
    }

    func testGermanMapsToLatin() {
        XCTAssertEqual(dominantScript(for: Locale(identifier: "de_DE")), .latin)
    }

    func testPortugueseMapsToLatin() {
        XCTAssertEqual(dominantScript(for: Locale(identifier: "pt_BR")), .latin)
    }

    func testTurkishMapsToLatin() {
        XCTAssertEqual(dominantScript(for: Locale(identifier: "tr_TR")), .latin)
    }

    // MARK: - Cyrillic script

    func testRussianMapsToCyrillic() {
        XCTAssertEqual(dominantScript(for: Locale(identifier: "ru_RU")), .cyrillic)
    }

    func testUkrainianMapsToCyrillic() {
        XCTAssertEqual(dominantScript(for: Locale(identifier: "uk_UA")), .cyrillic)
    }

    // MARK: - CJK script

    func testJapaneseMapsToCJK() {
        XCTAssertEqual(dominantScript(for: Locale(identifier: "ja_JP")), .cjk)
    }

    func testKoreanMapsToCJK() {
        XCTAssertEqual(dominantScript(for: Locale(identifier: "ko_KR")), .cjk)
    }

    func testChineseSimplifiedMapsToCJK() {
        XCTAssertEqual(dominantScript(for: Locale(identifier: "zh_CN")), .cjk)
    }

    // MARK: - Arabic script

    func testArabicMapsToArabic() {
        XCTAssertEqual(dominantScript(for: Locale(identifier: "ar_SA")), .arabic)
    }

    func testUrduMapsToArabic() {
        XCTAssertEqual(dominantScript(for: Locale(identifier: "ur_PK")), .arabic)
    }

    // MARK: - Devanagari script

    func testHindiMapsToDevanagari() {
        XCTAssertEqual(dominantScript(for: Locale(identifier: "hi_IN")), .devanagari)
    }

    // MARK: - Other / unknown

    func testGreekMapsToOther() {
        XCTAssertEqual(dominantScript(for: Locale(identifier: "el_GR")), .other)
    }

    func testUnknownLocaleMapsToOther() {
        XCTAssertEqual(dominantScript(for: Locale(identifier: "xx_XX")), .other)
    }

    // MARK: - isCJK helper

    func testCJKIsCJKReturnsTrue() {
        XCTAssertTrue(ScriptCategory.cjk.isCJK)
    }

    func testLatinIsCJKReturnsFalse() {
        XCTAssertFalse(ScriptCategory.latin.isCJK)
    }

    func testCyrillicIsCJKReturnsFalse() {
        XCTAssertFalse(ScriptCategory.cyrillic.isCJK)
    }
}
