import Foundation
import Testing

// Integration test: asserts that run_all.sh has been executed and produced a
// PASS verdict in results/summary.json.
// This test FAILS if run_all.sh has not been run yet, or if any criterion failed.
// Do NOT modify this test to weaken the verdict check — that is the NO-SKIPPING contract.
@Suite("Integration")
struct IntegrationTests {

    @Test("summary.json verdict is PASS")
    func summaryVerdictIsPass() throws {
        let summaryURL = summaryJSONURL()

        guard FileManager.default.fileExists(atPath: summaryURL.path) else {
            Issue.record(
                "results/summary.json not found at \(summaryURL.path). Run ./run_all.sh first."
            )
            return
        }

        let data = try Data(contentsOf: summaryURL)
        let json = try JSONDecoder().decode(SummaryVerdict.self, from: data)

        if json.verdict != "PASS" {
            let reasons = json.verdictReasons.joined(separator: "\n  ")
            Issue.record(
                "Spike #17.1 verdict is \(json.verdict). Reasons:\n  \(reasons)"
            )
        }
        #expect(json.verdict == "PASS")
    }

    private func summaryJSONURL() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        // Walk up from Tests/Spike17_1Tests/IntegrationTests.swift → spike root
        url = url.deletingLastPathComponent()  // → Spike17_1Tests/
            .deletingLastPathComponent()       // → Tests/
            .deletingLastPathComponent()       // → spike root
        return url.appendingPathComponent("results/summary.json")
    }

    private struct SummaryVerdict: Decodable {
        let verdict: String
        let verdictReasons: [String]
    }
}
