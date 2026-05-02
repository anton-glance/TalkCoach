import Foundation
import WPMCalcCopy
import os

private let logger = Logger(
    subsystem: "com.speechcoach.app",
    category: "parakeet-timestamps"
)

enum TimestampValidator {

    struct ValidationResult {
        let clipName: String
        let groundTruthWPM: Double
        let computedWPM: Double
        let errorPercent: Double
        let wordCount: Int
        let speakingDuration: TimeInterval
        let timestampGranularity: String
        let averageGapBetweenWords: Double
        let medianTokenDuration: Double
    }

    static func validate(
        words: [MergedWord],
        clipName: String,
        groundTruthWPM: Double
    ) -> ValidationResult {
        let timestamped = words.map {
            TimestampedWord(
                word: $0.word,
                startTime: $0.startTime,
                endTime: $0.endTime
            )
        }

        var calc = WPMCalculator(
            windowSize: 6.0,
            emaAlpha: 0.3,
            tokenSilenceTimeout: 1.5
        )
        for w in timestamped { calc.addWord(w) }

        let avgWPM = calc.sessionAverageWPM
        let errorPct = groundTruthWPM > 0
            ? abs(avgWPM - groundTruthWPM) / groundTruthWPM * 100.0
            : 0

        let gaps = computeGaps(words: words)
        let avgGap = gaps.isEmpty
            ? 0
            : gaps.reduce(0, +) / Double(gaps.count)

        let durations = words.map { $0.endTime - $0.startTime }
        let medianDur = median(durations)

        let granularity = classifyGranularity(
            words: words, gaps: gaps
        )

        logger.info(
            "\(clipName): computed=\(String(format: "%.1f", avgWPM)) WPM, gt=\(String(format: "%.1f", groundTruthWPM)) WPM, error=\(String(format: "%.1f", errorPct))%, granularity=\(granularity)"
        )

        return ValidationResult(
            clipName: clipName,
            groundTruthWPM: groundTruthWPM,
            computedWPM: avgWPM,
            errorPercent: errorPct,
            wordCount: words.count,
            speakingDuration: calc.totalSpeakingDuration,
            timestampGranularity: granularity,
            averageGapBetweenWords: avgGap,
            medianTokenDuration: medianDur
        )
    }

    // MARK: - Private

    private static func computeGaps(
        words: [MergedWord]
    ) -> [Double] {
        guard words.count > 1 else { return [] }
        var gaps: [Double] = []
        for i in 1..<words.count {
            let gap = words[i].startTime - words[i - 1].endTime
            gaps.append(gap)
        }
        return gaps
    }

    private static func classifyGranularity(
        words: [MergedWord],
        gaps: [Double]
    ) -> String {
        guard !gaps.isEmpty else { return "insufficient-data" }

        let distinctGaps = gaps.filter { $0 > 0.01 }
        let fractionWithGaps = Double(distinctGaps.count)
            / Double(gaps.count)

        if fractionWithGaps > 0.5 {
            return "word-level"
        } else if fractionWithGaps > 0.1 {
            return "mixed"
        } else {
            return "phrase-level"
        }
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }
}
