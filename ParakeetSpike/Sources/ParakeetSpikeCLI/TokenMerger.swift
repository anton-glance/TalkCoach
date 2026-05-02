import Foundation

struct MergedWord: Sendable {
    let word: String
    let startTime: Double
    let endTime: Double
    let confidence: Float
}

enum TokenMerger {

    static func merge(
        tokens: [(token: String, startTime: Double, endTime: Double, confidence: Float)]
    ) -> [MergedWord] {
        guard !tokens.isEmpty else { return [] }

        var result: [MergedWord] = []
        var currentWord = ""
        var currentStart: Double = 0
        var currentEnd: Double = 0
        var currentConfidence: Float = 0
        var pieceCount = 0

        for (i, t) in tokens.enumerated() {
            let text = t.token
            let isNewWord = i == 0
                || text.hasPrefix(" ")
                || text.hasPrefix("\u{2581}")

            if isNewWord && pieceCount > 0 {
                let trimmed = currentWord
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    result.append(MergedWord(
                        word: trimmed,
                        startTime: currentStart,
                        endTime: currentEnd,
                        confidence: currentConfidence / Float(pieceCount)
                    ))
                }
                currentWord = ""
                pieceCount = 0
            }

            if pieceCount == 0 {
                currentStart = t.startTime
                currentConfidence = 0
            }

            let cleaned = text
                .replacingOccurrences(of: "\u{2581}", with: "")
            currentWord += cleaned
            currentEnd = t.endTime
            currentConfidence += t.confidence
            pieceCount += 1
        }

        if pieceCount > 0 {
            let trimmed = currentWord
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.append(MergedWord(
                    word: trimmed,
                    startTime: currentStart,
                    endTime: currentEnd,
                    confidence: currentConfidence / Float(pieceCount)
                ))
            }
        }

        return result
    }
}
