import XCTest

final class IntegrationTests: XCTestCase {

    func testSummaryVerdictIsPass() throws {
        // Locate summary.json relative to this file's directory
        let thisFile = URL(fileURLWithPath: #filePath)
        let spikeDir = thisFile
            .deletingLastPathComponent()  // Spike16Tests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Spike16_BufferLevelVAD
        let summaryURL = spikeDir.appendingPathComponent("results/summary.json")

        guard FileManager.default.fileExists(atPath: summaryURL.path) else {
            throw XCTSkip("results/summary.json not found — run run_all.sh first")
        }

        let data = try Data(contentsOf: summaryURL)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let verdict = json["verdict"] as? String else {
            XCTFail("Cannot parse summary.json")
            return
        }

        if verdict != "PASS" {
            let reasons = json["verdictReasons"] as? [[String: Any]] ?? []
            var msg = "Verdict: \(verdict)\n"
            for r in reasons {
                let crit = r["criterion"] as? String ?? "?"
                let exp = r["expected"] as? String ?? "?"
                let act = r["actual"] as? String ?? "?"
                let disp = r["disposition"] as? String ?? "?"
                msg += "  [\(disp)] \(crit): expected \(exp), got \(act)\n"
            }
            XCTFail(msg)
        }
    }
}
