import Foundation

enum Disposition: String, Codable {
    case pass    = "PASS"
    case fail    = "FAIL"
    case skip    = "SKIP"
    case blocked = "BLOCKED"
}

struct CriterionResult: Codable {
    var id: String
    var name: String
    var disposition: Disposition
    var measured: String
    var budget: String
    var notes: String
}

struct ManifestEvent {
    var clip: String
    var mic: String
    var eventType: String
    var eventSeconds: Double
}

struct ClipKey: Hashable {
    var clip: String
    var mic: String
}

// Fix 4: added audioSamplePositionMs field.
// CSV columns: 0=update_index, 1=emission_ms, 2=gap, 3=audio_sample_position_ms,
//              4=text(quoted), 5=is_confirmed, 6=confidence
struct TokenRow {
    var updateIndex: Int
    var emissionMs: Double
    var gapFromPreviousMs: Double
    var audioSamplePositionMs: Int   // Fix 4
    var text: String
    var isConfirmed: Bool
    var confidence: Float
}

// ---- Revision 1 — kLengthMs-conditional budget rules ----
// Standard (kLengthMs >= 1000): C6 budget = 0, C9 threshold = baseline * 0.90
// Strict   (kLengthMs <= 800):  C6 budget <= 5, C9 threshold = baseline * 0.92

struct BudgetRules {
    var c6GhostTokenBudget: Int     // 0 or 5
    var c9ThresholdMultiplier: Double  // 0.90 or 0.92
    var strictMode: Bool
}

func budgetRulesFor(kLengthMs: Int) -> BudgetRules {
    if kLengthMs <= 800 {
        return BudgetRules(c6GhostTokenBudget: 5, c9ThresholdMultiplier: 0.92, strictMode: true)
    } else {
        return BudgetRules(c6GhostTokenBudget: 0, c9ThresholdMultiplier: 0.90, strictMode: false)
    }
}

// ---- Criteria scoring ---------------------------------------------------------

struct CriteriaScorer {
    var bootstrapJSON: [String: Any]
    var smokeBaseline: [String: Any]
    var fixtureRows: [String: [TokenRow]]
    var manifest: [ClipKey: [ManifestEvent]]
    var kLengthMs: Int   // Revision 1: drives budget rule selection

    var rules: BudgetRules { budgetRulesFor(kLengthMs: kLengthMs) }

    func scoreC1() -> CriterionResult {
        CriterionResult(id: "C1", name: "Models load", disposition: .pass,
                        measured: "eval reached", budget: "no crash", notes: "")
    }

    func scoreC2() -> CriterionResult {
        CriterionResult(id: "C2", name: "No crash on feed", disposition: .pass,
                        measured: "eval reached", budget: "no crash", notes: "")
    }

    func scoreC3() -> CriterionResult {
        let speechFixtures = fixtureRows.filter { k, _ in !k.hasPrefix("silence_only") }
        var perFixture: [(String, Bool)] = []
        for (name, rows) in speechFixtures {
            let nonEmpty = rows.filter { !$0.text.isEmpty }
            let maxMs = rows.map(\.emissionMs).max() ?? 0
            let expectedMinUpdates = max(1, Int(maxMs / 5_000))
            perFixture.append((name, nonEmpty.count >= expectedMinUpdates))
        }
        let passCount = perFixture.filter(\.1).count
        let total = perFixture.count
        let ratio = total > 0 ? Double(passCount) / Double(total) : 1.0
        return CriterionResult(
            id: "C3", name: "Update density ≥1/5s",
            disposition: ratio >= 0.8 ? .pass : .fail,
            measured: "\(passCount)/\(total) fixtures",
            budget: "≥1 update per 5s",
            notes: perFixture.filter { !$0.1 }.map(\.0).joined(separator: ", ")
        )
    }

    func scoreC4() -> CriterionResult {
        let ms = bootstrapJSON["c4FirstTokenMs"] as? Double ?? -1
        let budget = 200.0
        let disp: Disposition
        if ms < 0 { disp = .blocked }
        else if ms <= budget { disp = .pass }
        else { disp = .fail }
        return CriterionResult(
            id: "C4", name: "First-token latency ≤200ms",
            disposition: disp,
            measured: ms < 0 ? "no token" : String(format: "%.0f ms", ms),
            budget: "≤200 ms",
            notes: ms > 2000 ? "10× BUDGET MISS — NO-SKIPPING rule triggered" : ""
        )
    }

    func scoreC5() -> CriterionResult {
        var allGaps: [Double] = []
        for (name, rows) in fixtureRows where !name.hasPrefix("silence_only") {
            allGaps.append(contentsOf: rows.dropFirst().map(\.gapFromPreviousMs))
        }
        allGaps.sort()
        guard !allGaps.isEmpty else {
            return CriterionResult(id: "C5", name: "p95 gap ≤800ms", disposition: .blocked,
                                   measured: "no data", budget: "≤800ms", notes: "")
        }
        let p95idx = Int(Double(allGaps.count) * 0.95)
        let p95 = allGaps[min(p95idx, allGaps.count - 1)]
        return CriterionResult(
            id: "C5", name: "p95 inter-update gap ≤800ms",
            disposition: p95 <= 800 ? .pass : .fail,
            measured: String(format: "%.0f ms", p95),
            budget: "≤800 ms",
            notes: "n=\(allGaps.count)"
        )
    }

    func scoreC6() -> CriterionResult {
        let silenceFixtures = fixtureRows.filter { k, _ in k.hasPrefix("silence_only") }
        if silenceFixtures.isEmpty {
            return CriterionResult(id: "C6", name: "No hallucinations", disposition: .blocked,
                                   measured: "no silence fixtures", budget: "0 tokens", notes: "")
        }
        var hallucinationCount = 0
        var details: [String] = []
        for (name, rows) in silenceFixtures {
            let nonempty = rows.filter { !$0.text.isEmpty }
            if !nonempty.isEmpty {
                hallucinationCount += nonempty.count
                details.append("\(name): \(nonempty.count) ghost tokens")
            }
        }

        // Revision 1: conditional budget
        let budget = rules.c6GhostTokenBudget
        let budgetStr = budget == 0 ? "0 ghost tokens" : "≤\(budget) ghost tokens (strict mode kLengthMs≤800)"
        return CriterionResult(
            id: "C6", name: "No hallucinations on silence",
            disposition: hallucinationCount <= budget ? .pass : .fail,
            measured: "\(hallucinationCount) ghost tokens",
            budget: budgetStr,
            notes: details.joined(separator: "; ")
        )
    }

    func scoreC7() -> CriterionResult {
        CriterionResult(id: "C7", name: "Text intelligibility", disposition: .skip,
                        measured: "manual review needed", budget: "informal",
                        notes: "Check CSV text column")
    }

    // Fix 4: C8 now uses audioSamplePositionMs (audio-domain time) instead of emissionMs.
    // This corrects the time-base mismatch from #17.2 where wall-clock emission_ms
    // (including ~40s Metal JIT) was compared against audio-domain manifest timestamps.
    func scoreC8() -> CriterionResult {
        var detected = 0
        var total    = 0

        let altFixtures = fixtureRows.filter { k, _ in k.hasPrefix("alternating") }
        for (fixtureName, rows) in altFixtures {
            let parts = fixtureName.split(separator: "_").map(String.init)
            guard parts.count >= 2 else { continue }
            let clip = parts[0]
            let mic  = parts[1]
            let key  = ClipKey(clip: clip, mic: mic)
            guard let events = manifest[key] else { continue }

            let speechEnds = events.filter { $0.eventType == "speech_end" }
            // Fix 4: use audio-domain position, not wall-clock emissionMs
            let confirmedAudioMs = rows.filter(\.isConfirmed).map { Double($0.audioSamplePositionMs) }

            for se in speechEnds {
                let seMs = se.eventSeconds * 1_000
                total += 1
                let found = confirmedAudioMs.contains { abs($0 - seMs) <= 500 }
                if found { detected += 1 }
            }
        }

        guard total > 0 else {
            return CriterionResult(id: "C8", name: "Silence boundary ≥83.3%", disposition: .blocked,
                                   measured: "no alternating fixtures", budget: "≥5/6", notes: "")
        }
        let ratio = Double(detected) / Double(total)
        return CriterionResult(
            id: "C8", name: "Silence boundary detection ≥83.3%",
            disposition: ratio >= 0.833 ? .pass : .fail,
            measured: String(format: "%d/%d (%.1f%%)", detected, total, ratio * 100),
            budget: "≥83.3% (5/6)",
            notes: "using audioSamplePositionMs (Fix 4)"
        )
    }

    func scoreC9() -> CriterionResult {
        let baseline = smokeBaseline["medianLogProb"] as? Double ?? -1
        var allConf: [Float] = []
        for (name, rows) in fixtureRows where !name.hasPrefix("silence_only") {
            let confirmed = rows.filter { $0.isConfirmed && $0.confidence >= 0 }
            allConf.append(contentsOf: confirmed.map(\.confidence))
        }
        allConf.sort()
        guard !allConf.isEmpty else {
            return CriterionResult(id: "C9", name: "Confidence signal", disposition: .blocked,
                                   measured: "no confirmed events", budget: "≥baseline×multiplier", notes: "")
        }
        let median = Double(allConf[allConf.count / 2])

        // Revision 1: conditional multiplier
        let multiplier = rules.c9ThresholdMultiplier
        let threshold = baseline >= 0 ? baseline * multiplier : 0.30
        let budgetStr: String
        if rules.strictMode {
            budgetStr = String(format: "≥%.3f (baseline=%.3f × %.2f strict kLengthMs≤800)", threshold, baseline, multiplier)
        } else {
            budgetStr = String(format: "≥%.3f (baseline=%.3f × %.2f)", threshold, baseline, multiplier)
        }
        return CriterionResult(
            id: "C9", name: "Median confidence ≥ baseline×multiplier",
            disposition: median >= threshold ? .pass : .fail,
            measured: String(format: "%.3f", median),
            budget: budgetStr,
            notes: "n=\(allConf.count)"
        )
    }

    func scoreC10() -> CriterionResult {
        let cafeFixtures = fixtureRows.filter { k, _ in k.hasPrefix("cafe_noise") }
        if cafeFixtures.isEmpty {
            return CriterionResult(id: "C10", name: "Cafe noise resilience", disposition: .blocked,
                                   measured: "no cafe fixtures", budget: "≥1 token", notes: "")
        }
        var failures: [String] = []
        for (name, rows) in cafeFixtures {
            if rows.filter({ !$0.text.isEmpty }).isEmpty { failures.append(name) }
        }
        return CriterionResult(
            id: "C10", name: "Cafe noise: ≥1 non-empty token",
            disposition: failures.isEmpty ? .pass : .fail,
            measured: "\(cafeFixtures.count - failures.count)/\(cafeFixtures.count) fixtures transcribed",
            budget: "all cafe fixtures non-empty",
            notes: failures.joined(separator: ", ")
        )
    }

    func scoreC11() -> CriterionResult {
        let rssMB = bootstrapJSON["rssAfterFirstInferenceMB"] as? Double ?? -1
        let budgetMB = 1_024.0
        let disp: Disposition = rssMB < 0 ? .blocked : (rssMB <= budgetMB ? .pass : .fail)
        return CriterionResult(
            id: "C11", name: "Peak RSS ≤1 GB",
            disposition: disp,
            measured: rssMB < 0 ? "unknown" : String(format: "%.1f MB", rssMB),
            budget: "≤1024 MB (spike-specific; see R2/R4)",
            notes: ""
        )
    }

    // C12: updated — checks fixtureRows for real_world_test; PASS if transcription produced.
    func scoreC12() -> CriterionResult {
        guard let rows = fixtureRows["real_world_test"] else {
            return CriterionResult(id: "C12", name: "Real-world fixture", disposition: .skip,
                                   measured: "CSV not found", budget: "≥1 token",
                                   notes: "real_world_test fixture missing from results")
        }
        let nonempty = rows.filter { !$0.text.isEmpty }
        return CriterionResult(
            id: "C12", name: "Real-world fixture",
            disposition: nonempty.isEmpty ? .fail : .pass,
            measured: "\(nonempty.count) events",
            budget: "≥1 token",
            notes: nonempty.isEmpty ? "no transcription produced" : ""
        )
    }

    func scoreAll() -> [CriterionResult] {
        [scoreC1(), scoreC2(), scoreC3(), scoreC4(), scoreC5(),
         scoreC6(), scoreC7(), scoreC8(), scoreC9(), scoreC10(),
         scoreC11(), scoreC12()]
    }
}
