import Testing
@testable import LangDetectSpikeLib

struct ThresholdAnalyzerTests {

    @Test func emptyInputsReturnsNil() {
        let result = ThresholdAnalyzer.findOptimalThreshold(
            correctGuessWordCounts: [],
            wrongGuessWordCounts: []
        )
        #expect(result == nil)
    }

    @Test func perfectSeparation() {
        let result = ThresholdAnalyzer.findOptimalThreshold(
            correctGuessWordCounts: [20, 25, 22, 18],
            wrongGuessWordCounts: [2, 3, 1, 4]
        )
        #expect(result != nil)
        #expect(result!.accuracy == 1.0)
        #expect(result!.threshold > 4)
        #expect(result!.threshold <= 18)
        #expect(result!.total == 8)
    }

    @Test func noSeparation() {
        let result = ThresholdAnalyzer.findOptimalThreshold(
            correctGuessWordCounts: [10, 10, 10, 10],
            wrongGuessWordCounts: [10, 10, 10, 10]
        )
        #expect(result != nil)
        #expect(result!.accuracy <= 0.501)
    }

    @Test func partialSeparation() {
        // correctGuess: [15, 18, 8, 20], wrongGuess: [5, 8, 14, 3]
        // Overlap: correct has an 8, wrong has a 14.
        // Optimal threshold = 15: TP=4, TN=3, FP=1, FN=0 → accuracy 7/8 = 0.875
        let result = ThresholdAnalyzer.findOptimalThreshold(
            correctGuessWordCounts: [15, 18, 8, 20],
            wrongGuessWordCounts: [5, 8, 14, 3]
        )
        #expect(result != nil)
        #expect(result!.accuracy > 0.5)
        #expect(result!.accuracy < 1.0)
        #expect(result!.total == 8)
    }

    @Test func singleElementPerGroup() {
        let result = ThresholdAnalyzer.findOptimalThreshold(
            correctGuessWordCounts: [20],
            wrongGuessWordCounts: [5]
        )
        #expect(result != nil)
        #expect(result!.accuracy == 1.0)
        #expect(result!.total == 2)
        #expect(result!.truePositives == 1)
        #expect(result!.trueNegatives == 1)
        #expect(result!.falsePositives == 0)
        #expect(result!.falseNegatives == 0)
    }

    @Test func thresholdClassifiesBelowAsSwapNeeded() {
        // Below threshold → classified as "wrong guess" → swap needed → true positive
        // At or above threshold → classified as "correct guess" → no swap → true negative
        let result = ThresholdAnalyzer.findOptimalThreshold(
            correctGuessWordCounts: [20, 25],
            wrongGuessWordCounts: [3, 5]
        )
        #expect(result != nil)
        #expect(result!.truePositives == 2)
        #expect(result!.trueNegatives == 2)
        #expect(result!.falsePositives == 0)
        #expect(result!.falseNegatives == 0)
    }

    @Test func onlyCorrectGuessSamples() {
        let result = ThresholdAnalyzer.findOptimalThreshold(
            correctGuessWordCounts: [10, 15, 20],
            wrongGuessWordCounts: []
        )
        #expect(result != nil)
        #expect(result!.accuracy == 1.0)
        #expect(result!.trueNegatives == 3)
        #expect(result!.truePositives == 0)
    }

    @Test func onlyWrongGuessSamples() {
        let result = ThresholdAnalyzer.findOptimalThreshold(
            correctGuessWordCounts: [],
            wrongGuessWordCounts: [5, 8, 3]
        )
        #expect(result != nil)
        #expect(result!.accuracy == 1.0)
        #expect(result!.truePositives == 3)
        #expect(result!.trueNegatives == 0)
    }
}
