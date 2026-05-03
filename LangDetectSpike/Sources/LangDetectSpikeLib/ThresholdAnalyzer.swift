public struct ThresholdSearchResult: Sendable, Equatable {
    public let threshold: Int
    public let accuracy: Double
    public let truePositives: Int
    public let falsePositives: Int
    public let trueNegatives: Int
    public let falseNegatives: Int
    public let total: Int

    public init(
        threshold: Int,
        accuracy: Double,
        truePositives: Int,
        falsePositives: Int,
        trueNegatives: Int,
        falseNegatives: Int,
        total: Int
    ) {
        self.threshold = threshold
        self.accuracy = accuracy
        self.truePositives = truePositives
        self.falsePositives = falsePositives
        self.trueNegatives = trueNegatives
        self.falseNegatives = falseNegatives
        self.total = total
    }
}

public struct ThresholdAnalyzer: Sendable {
    /// Finds the word-count threshold that maximizes swap-detection accuracy.
    ///
    /// Semantics: a sample with word count BELOW the threshold is classified as
    /// "wrong guess" (swap needed). At or above is "correct guess" (no swap).
    ///
    /// - `correctGuessWordCounts`: word counts from runs where the transcriber
    ///   was initialized with the correct language (expected: higher counts).
    /// - `wrongGuessWordCounts`: word counts from runs where the transcriber
    ///   was initialized with the wrong language (expected: lower counts).
    public static func findOptimalThreshold(
        correctGuessWordCounts: [Int],
        wrongGuessWordCounts: [Int]
    ) -> ThresholdSearchResult? {
        let allValues = correctGuessWordCounts + wrongGuessWordCounts
        guard !allValues.isEmpty else { return nil }

        let candidates = Set(allValues.flatMap { [$0, $0 + 1] }).sorted()
        var best: ThresholdSearchResult?

        for t in candidates {
            let tp = wrongGuessWordCounts.count(where: { $0 < t })
            let fn = wrongGuessWordCounts.count(where: { $0 >= t })
            let tn = correctGuessWordCounts.count(where: { $0 >= t })
            let fp = correctGuessWordCounts.count(where: { $0 < t })
            let total = tp + fn + tn + fp
            let accuracy = total > 0 ? Double(tp + tn) / Double(total) : 0

            let result = ThresholdSearchResult(
                threshold: t,
                accuracy: accuracy,
                truePositives: tp,
                falsePositives: fp,
                trueNegatives: tn,
                falseNegatives: fn,
                total: total
            )

            if best == nil || accuracy > best!.accuracy {
                best = result
            }
        }

        return best
    }
}
