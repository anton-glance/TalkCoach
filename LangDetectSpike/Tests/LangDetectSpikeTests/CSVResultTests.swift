import Testing
@testable import LangDetectSpikeLib

// MARK: - Option B

struct OptionBResultTests {

    @Test func csvHeaderContainsAllColumns() {
        let header = OptionBResult.csvHeader
        let columns = header.split(separator: ",").map(String.init)
        #expect(columns.count == 12)
        #expect(columns[0] == "clip")
        #expect(columns[1] == "pair")
        #expect(columns[2] == "ground_truth_lang")
        #expect(columns[3] == "initialized_lang")
        #expect(columns[4] == "guess_mode")
        #expect(columns[5] == "partial_text")
        #expect(columns[6] == "words_emitted_in_5s")
        #expect(columns[7] == "detected_lang")
        #expect(columns[8] == "confidence_correct")
        #expect(columns[9] == "confidence_wrong")
        #expect(columns[10] == "correct_detection")
        #expect(columns[11] == "time_to_decision_s")
    }

    @Test func csvRowFormatsTypicalValues() {
        let result = OptionBResult(
            clip: "ru_01.caf",
            pair: "en+ru",
            groundTruthLang: "ru",
            initializedLang: "en",
            guessMode: .wrong,
            partialText: "hello world test",
            wordsEmittedIn5s: 3,
            detectedLang: "ru",
            confidenceCorrect: 0.8765,
            confidenceWrong: 0.1235,
            correctDetection: true,
            timeToDecisionS: 5.123
        )

        let columns = parseCSVRow(result.csvRow)
        #expect(columns[0] == "ru_01.caf")
        #expect(columns[1] == "en+ru")
        #expect(columns[2] == "ru")
        #expect(columns[3] == "en")
        #expect(columns[4] == "wrong")
        #expect(columns[5] == "hello world test")
        #expect(columns[6] == "3")
        #expect(columns[7] == "ru")
        #expect(columns[8] == "0.8765")
        #expect(columns[9] == "0.1235")
        #expect(columns[10] == "true")
        #expect(columns[11] == "5.123")
    }

    @Test func csvRowEscapesQuotesInPartialText() {
        let result = OptionBResult(
            clip: "en_01.caf",
            pair: "en+ru",
            groundTruthLang: "en",
            initializedLang: "ru",
            guessMode: .wrong,
            partialText: "he said \"hello\" to me",
            wordsEmittedIn5s: 6,
            detectedLang: "en",
            confidenceCorrect: 0.9,
            confidenceWrong: 0.1,
            correctDetection: true,
            timeToDecisionS: 5.0
        )

        let columns = parseCSVRow(result.csvRow)
        #expect(columns[5] == "he said \"hello\" to me")
    }

    @Test func csvRowHandlesCommasInPartialText() {
        let result = OptionBResult(
            clip: "es_01.caf",
            pair: "en+es",
            groundTruthLang: "es",
            initializedLang: "en",
            guessMode: .wrong,
            partialText: "yes, no, maybe",
            wordsEmittedIn5s: 3,
            detectedLang: "es",
            confidenceCorrect: 0.7,
            confidenceWrong: 0.3,
            correctDetection: true,
            timeToDecisionS: 5.0
        )

        let columns = parseCSVRow(result.csvRow)
        #expect(columns.count == 12)
        #expect(columns[5] == "yes, no, maybe")
    }

    @Test func csvRowCorrectGuessMode() {
        let result = OptionBResult(
            clip: "en_02.caf",
            pair: "en+ja",
            groundTruthLang: "en",
            initializedLang: "en",
            guessMode: .correct,
            partialText: "testing one two three",
            wordsEmittedIn5s: 4,
            detectedLang: "en",
            confidenceCorrect: 0.95,
            confidenceWrong: 0.05,
            correctDetection: true,
            timeToDecisionS: 5.0
        )

        let columns = parseCSVRow(result.csvRow)
        #expect(columns[4] == "correct")
    }

    @Test func csvRowEmptyPartialText() {
        let result = OptionBResult(
            clip: "ja_01.caf",
            pair: "en+ja",
            groundTruthLang: "ja",
            initializedLang: "en",
            guessMode: .wrong,
            partialText: "",
            wordsEmittedIn5s: 0,
            detectedLang: "undetermined",
            confidenceCorrect: 0.5,
            confidenceWrong: 0.5,
            correctDetection: false,
            timeToDecisionS: 5.0
        )

        let columns = parseCSVRow(result.csvRow)
        #expect(columns[5] == "")
        #expect(columns[6] == "0")
        #expect(columns[10] == "false")
    }
}

// MARK: - Option C

struct OptionCResultTests {

    @Test func csvHeaderContainsAllColumns() {
        let header = OptionCResult.csvHeader
        let columns = header.split(separator: ",").map(String.init)
        #expect(columns.count == 12)
        #expect(columns[0] == "clip")
        #expect(columns[4] == "window_s")
        #expect(columns[9] == "inference_time_ms")
        #expect(columns[10] == "model_name")
        #expect(columns[11] == "model_size_mb")
    }

    @Test func csvRowFormatsTypicalValues() {
        let result = OptionCResult(
            clip: "ru_01.caf",
            pair: "en+ru",
            groundTruthLang: "ru",
            declaredPair: "en+ru",
            windowS: 3.0,
            detectedLang: "ru",
            confidenceCorrect: 0.95,
            confidenceWrong: 0.05,
            correctDetection: true,
            inferenceTimeMs: 42.5,
            modelName: "ecapa-lid",
            modelSizeMb: 90.0
        )

        let columns = result.csvRow.split(separator: ",").map(String.init)
        #expect(columns[0] == "ru_01.caf")
        #expect(columns[1] == "en+ru")
        #expect(columns[2] == "ru")
        #expect(columns[3] == "en+ru")
        #expect(columns[4] == "3.0")
        #expect(columns[5] == "ru")
        #expect(columns[8] == "true")
        #expect(columns[10] == "ecapa-lid")
    }

    @Test func csvRowFormats5SecondWindow() {
        let result = OptionCResult(
            clip: "ja_02.caf",
            pair: "en+ja",
            groundTruthLang: "ja",
            declaredPair: "en+ja",
            windowS: 5.0,
            detectedLang: "ja",
            confidenceCorrect: 0.88,
            confidenceWrong: 0.12,
            correctDetection: true,
            inferenceTimeMs: 55.0,
            modelName: "ecapa-lid",
            modelSizeMb: 90.0
        )

        let columns = result.csvRow.split(separator: ",").map(String.init)
        #expect(columns[4] == "5.0")
    }
}

// MARK: - CSV Parsing Helper

/// Simple CSV row parser that handles quoted fields with embedded commas and escaped quotes.
func parseCSVRow(_ row: String) -> [String] {
    var columns: [String] = []
    var current = ""
    var inQuotes = false
    var i = row.startIndex

    while i < row.endIndex {
        let char = row[i]
        if char == "\"" {
            if inQuotes {
                let next = row.index(after: i)
                if next < row.endIndex && row[next] == "\"" {
                    current.append("\"")
                    i = row.index(after: next)
                    continue
                } else {
                    inQuotes = false
                }
            } else {
                inQuotes = true
            }
        } else if char == "," && !inQuotes {
            columns.append(current)
            current = ""
        } else {
            current.append(char)
        }
        i = row.index(after: i)
    }
    columns.append(current)
    return columns
}
