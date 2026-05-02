import Foundation

enum WERCalculator {

    struct WERResult {
        let wer: Double
        let referenceCount: Int
        let substitutions: Int
        let insertions: Int
        let deletions: Int
    }

    struct FillerResult {
        let filler: String
        let expectedCount: Int
        let recognizedCount: Int
        let rate: Double
    }

    static func compute(
        hypothesis: [MergedWord],
        referenceText: String
    ) -> WERResult {
        let refWords = normalize(referenceText)
        let hypWords = hypothesis.map { normalize($0.word) }
            .flatMap { $0 }

        let (s, i, d) = editDistance(ref: refWords, hyp: hypWords)
        let wer = refWords.isEmpty ? 0 : Double(s + i + d) / Double(refWords.count)

        return WERResult(
            wer: wer,
            referenceCount: refWords.count,
            substitutions: s,
            insertions: i,
            deletions: d
        )
    }

    static func computeFillerRecognition(
        hypothesis: [MergedWord],
        referenceText: String,
        fillers: [String]
    ) -> [FillerResult] {
        let refNorm = referenceText.lowercased()
        let hypText = hypothesis.map { $0.word.lowercased() }
            .joined(separator: " ")

        return fillers.map { filler in
            let fillerLower = filler.lowercased()
            let expectedCount = countOccurrences(
                of: fillerLower, in: refNorm
            )
            let recognizedCount = countOccurrences(
                of: fillerLower, in: hypText
            )
            let rate = expectedCount > 0
                ? Double(min(recognizedCount, expectedCount))
                    / Double(expectedCount)
                : (recognizedCount > 0 ? 1.0 : 0.0)

            return FillerResult(
                filler: filler,
                expectedCount: expectedCount,
                recognizedCount: recognizedCount,
                rate: rate
            )
        }
    }

    // MARK: - Private

    private static func normalize(_ text: String) -> [String] {
        let lowered = text.lowercased()
        let cleaned = lowered.unicodeScalars.filter {
            CharacterSet.letters.contains($0)
                || CharacterSet.whitespaces.contains($0)
                || $0 == "\u{0301}"
        }
        return String(cleaned)
            .split(separator: " ")
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    private static func editDistance(
        ref: [String], hyp: [String]
    ) -> (substitutions: Int, insertions: Int, deletions: Int) {
        let n = ref.count
        let m = hyp.count

        struct Cell {
            var cost: Int
            var sub: Int
            var ins: Int
            var del: Int
        }

        var prev = (0...m).map { j in
            Cell(cost: j, sub: 0, ins: j, del: 0)
        }
        var curr = [Cell](
            repeating: Cell(cost: 0, sub: 0, ins: 0, del: 0),
            count: m + 1
        )

        for i in 1...n {
            curr[0] = Cell(cost: i, sub: 0, ins: 0, del: i)
            for j in 1...m {
                if ref[i - 1] == hyp[j - 1] {
                    curr[j] = prev[j - 1]
                } else {
                    let subCost = prev[j - 1].cost + 1
                    let insCost = curr[j - 1].cost + 1
                    let delCost = prev[j].cost + 1

                    if subCost <= insCost && subCost <= delCost {
                        curr[j] = Cell(
                            cost: subCost,
                            sub: prev[j - 1].sub + 1,
                            ins: prev[j - 1].ins,
                            del: prev[j - 1].del
                        )
                    } else if insCost <= delCost {
                        curr[j] = Cell(
                            cost: insCost,
                            sub: curr[j - 1].sub,
                            ins: curr[j - 1].ins + 1,
                            del: curr[j - 1].del
                        )
                    } else {
                        curr[j] = Cell(
                            cost: delCost,
                            sub: prev[j].sub,
                            ins: prev[j].ins,
                            del: prev[j].del + 1
                        )
                    }
                }
            }
            prev = curr
        }

        let final = prev[m]
        return (final.sub, final.ins, final.del)
    }

    private static func countOccurrences(
        of pattern: String, in text: String
    ) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(
            of: pattern,
            options: .literal,
            range: searchRange
        ) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }
}
