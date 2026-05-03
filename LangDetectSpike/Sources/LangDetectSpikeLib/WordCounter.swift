public struct WordCounter: Sendable {
    public static func countWords(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
