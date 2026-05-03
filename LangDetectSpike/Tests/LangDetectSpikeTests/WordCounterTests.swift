import Testing
@testable import LangDetectSpikeLib

struct WordCounterTests {

    @Test func emptyString() {
        #expect(WordCounter.countWords(in: "") == 0)
    }

    @Test func whitespaceOnly() {
        #expect(WordCounter.countWords(in: "   \t\n  ") == 0)
    }

    @Test func singleWord() {
        #expect(WordCounter.countWords(in: "hello") == 1)
    }

    @Test func multipleWordsWithSpaces() {
        #expect(WordCounter.countWords(in: "the quick brown fox") == 4)
    }

    @Test func multipleWhitespaceTypes() {
        #expect(WordCounter.countWords(in: "hello\tworld\nfoo  bar") == 4)
    }

    @Test func cyrillicText() {
        #expect(WordCounter.countWords(in: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440} \u{0442}\u{0435}\u{0441}\u{0442}") == 3)
    }

    @Test func mixedScriptText() {
        #expect(WordCounter.countWords(in: "hello \u{043C}\u{0438}\u{0440} world") == 3)
    }

    @Test func leadingAndTrailingWhitespace() {
        #expect(WordCounter.countWords(in: "  hello world  ") == 2)
    }
}
