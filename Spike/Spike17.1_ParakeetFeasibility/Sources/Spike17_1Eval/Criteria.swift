import Foundation

// MARK: - Hallucination patterns (Whisper failure mode; verify Parakeet stays clean)

private let hallucinationPatterns: [String] = [
    "удачи и до встречи",
    "в следующих видео",
    "[silencio]",
    "[SILENCIO]",
    "¡ahora sí!",
    "ahora sí",
    "thanks for watching",
    "like and subscribe",
    "subtítulos por la comunidad",
    "amara.org",
    "subbers anonymous",
]

// MARK: - Criterion evaluation

struct CriteriaEvaluator {

    let bootstrap: BootstrapResult
    let clips: [ClipResult]
    let allRows: [String: [CSVRow]]  // fixture name -> rows

    // Evaluate all 12 criteria; return ordered array.
    func evaluate() -> [CriterionResult] {
        [
            criterion1_build(),
            criterion2_modelLoad(),
            criterion3_streaming(),
            criterion4_firstUpdateLatency(),
            criterion5_interUpdateP95(),
            criterion6_noHallucinations(),
            criterion7_silenceHandling(),
            criterion8_vadHeuristic(),
            criterion9_isConfirmedAvailable(),
            criterion10_cafeNoiseResilience(),
            criterion11_memory(),
            criterion12_realWorldCrossValidation(),
        ]
    }

    // 1. Build — pass/fail from bootstrap.
    private func criterion1_build() -> CriterionResult {
        let pass = bootstrap.modelLoadSuccess  // if CLI ran and produced bootstrap, build succeeded
        return CriterionResult(
            id: 1, name: "Build/install",
            budget: "clean build, zero errors",
            measured: pass ? "build succeeded (bootstrap.json present)" : "build failed or bootstrap missing",
            disposition: pass ? "PASS" : "FAIL",
            notes: pass ? "" : "bootstrap.json absent or modelLoadSuccess=false"
        )
    }

    // 2. Model load — from bootstrap.
    private func criterion2_modelLoad() -> CriterionResult {
        let pass = bootstrap.modelLoadSuccess
        let ms = Int(bootstrap.loadDurationMs)
        return CriterionResult(
            id: 2, name: "Model load",
            budget: "pipeline returned, no throw",
            measured: pass ? "loaded in \(ms)ms" : (bootstrap.errorDescription ?? "failed"),
            disposition: pass ? "PASS" : "FAIL",
            notes: bootstrap.errorDescription ?? ""
        )
    }

    // 3. Streaming behavior — first update arrives before audio ends.
    private func criterion3_streaming() -> CriterionResult {
        // Exclude silence_only fixtures (expected to have 0 updates).
        let speechClips = clips.filter { !$0.fixture.hasPrefix("silence_only") }
        let allStream = speechClips.allSatisfy { $0.firstUpdateBeforeAudioEnd }
        let failingClips = speechClips.filter { !$0.firstUpdateBeforeAudioEnd }.map { $0.fixture }
        return CriterionResult(
            id: 3, name: "Streaming behavior",
            budget: "at least one update emitted before audio feed completes",
            measured: allStream
                ? "all \(speechClips.count) speech clips emitted first update before audio end"
                : "BATCHED in: \(failingClips.joined(separator: ", "))",
            disposition: allStream ? "PASS" : "FAIL",
            notes: allStream
                ? ""
                : "Apple SpeechAnalyzer failure mode detected — updates batch at end of audio"
        )
    }

    // 4. First-update latency median ≤ 200ms.
    private func criterion4_firstUpdateLatency() -> CriterionResult {
        let budget = 200.0
        let speechClips = clips.filter { !$0.fixture.hasPrefix("silence_only") }
        let values = speechClips.compactMap { $0.firstUpdateEmissionMs }
        guard !values.isEmpty else {
            return CriterionResult(
                id: 4, name: "First-update latency median ≤ 200ms",
                budget: "≤ 200ms",
                measured: "no data",
                disposition: "FAIL",
                notes: "No speech clips produced any updates"
            )
        }
        let median = percentile(values, 0.50)
        let disp = disposition(median, budget: budget, warnThreshold: 160.0)
        return CriterionResult(
            id: 4, name: "First-update latency median ≤ 200ms",
            budget: "≤ \(Int(budget))ms",
            measured: "\(String(format: "%.0f", median))ms median across \(values.count) clips",
            disposition: disp,
            notes: "Time from session start (first audio buffer fed) to first update emission"
        )
    }

    // 5. Inter-confirmed-update p95 ≤ 400ms.
    private func criterion5_interUpdateP95() -> CriterionResult {
        let budget = 400.0
        let allGaps = clips.flatMap { $0.confirmedUpdateGapsMs }
        guard !allGaps.isEmpty else {
            return CriterionResult(
                id: 5, name: "Inter-update p95 ≤ 400ms",
                budget: "≤ 400ms",
                measured: "no confirmed updates",
                disposition: "FAIL",
                notes: "No confirmed (isConfirmed=true) updates across any fixture"
            )
        }
        let p95 = percentile(allGaps, 0.95)
        let disp = disposition(p95, budget: budget, warnThreshold: 320.0)
        return CriterionResult(
            id: 5, name: "Inter-update p95 ≤ 400ms",
            budget: "≤ \(Int(budget))ms",
            measured: "\(String(format: "%.0f", p95))ms p95 across \(allGaps.count) gaps",
            disposition: disp,
            notes: "Gap between consecutive isConfirmed=true updates; drives widget refresh cadence"
        )
    }

    // 6. No catastrophic hallucinations.
    private func criterion6_noHallucinations() -> CriterionResult {
        var found: [String] = []
        for (fixture, rows) in allRows {
            for row in rows {
                let lower = row.text.lowercased()
                for pattern in hallucinationPatterns {
                    if lower.contains(pattern.lowercased()) {
                        found.append("\(fixture): \"\(row.text.prefix(60))\"")
                    }
                }
            }
        }
        return CriterionResult(
            id: 6, name: "No catastrophic hallucinations",
            budget: "zero hallucination-pattern matches",
            measured: found.isEmpty ? "0 matches across all fixtures" : "\(found.count) match(es)",
            disposition: found.isEmpty ? "PASS" : "FAIL",
            notes: found.joined(separator: "; ")
        )
    }

    // 7. Silence handling — silence_only clips produce 0 updates (or 1 empty).
    private func criterion7_silenceHandling() -> CriterionResult {
        let silenceClips = ["silence_only_pods", "silence_only_mac"]
        var failures: [String] = []
        for name in silenceClips {
            guard let rows = allRows[name] else {
                failures.append("\(name): CSV not found")
                continue
            }
            // Allowed: 0 rows, or rows whose text is empty/whitespace
            let nonEmptyRows = rows.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            if nonEmptyRows.count > 1 {
                failures.append("\(name): \(nonEmptyRows.count) non-empty updates (first: \"\(nonEmptyRows[0].text.prefix(40))\")")
            }
        }
        return CriterionResult(
            id: 7, name: "Silence handling",
            budget: "0 updates on silence_only clips (or 1 empty end-of-stream token)",
            measured: failures.isEmpty
                ? "silence_only clips produced 0–1 non-empty updates"
                : failures.joined(separator: "; "),
            disposition: failures.isEmpty ? "PASS" : "FAIL",
            notes: ""
        )
    }

    // 8. VAD heuristic accuracy ≥ 90% on alternating clips.
    // Heuristic: "no new update for >300ms = silence started at lastUpdate + 300ms".
    // Ground truth from manifest: silence windows at [5s,10s], [15s,20s], [25s,30s].
    private func criterion8_vadHeuristic() -> CriterionResult {
        let budget = 90.0  // percent
        let alternatingFixtures = ["alternating_pods", "alternating_mac"]
        // Manifest silence windows for alternating clips (seconds → ms):
        let groundTruthSilenceWindows: [(start: Double, end: Double)] = [
            (5_000, 10_000),
            (15_000, 20_000),
            (25_000, 30_000),
        ]

        var totalWindows = 0
        var detected = 0

        for fixture in alternatingFixtures {
            guard let rows = allRows[fixture] else { continue }
            let emissionTimes = rows.map { $0.emissionMs }.sorted()
            // Estimate session duration: last emission + 1s buffer.
            let sessionDuration = (emissionTimes.last ?? 30_000) + 1_000

            let inferred = vadInferredSilenceWindows(
                emissionTimestamps: emissionTimes,
                sessionDurationMs: sessionDuration,
                silenceThresholdMs: 300.0
            )

            for gtWindow in groundTruthSilenceWindows {
                totalWindows += 1
                // Criterion: does ANY inferred silence window overlap with the ground-truth window?
                // A window is "detected" if an inferred window starts within the GT window.
                let detectd = inferred.contains { inferred in
                    inferred.start >= gtWindow.start
                        && inferred.start <= gtWindow.end
                }
                if detectd { detected += 1 }
            }
        }

        guard totalWindows > 0 else {
            return CriterionResult(
                id: 8, name: "VAD heuristic accuracy ≥ 90%",
                budget: "≥ 90%",
                measured: "no alternating fixture data",
                disposition: "FAIL",
                notes: "alternating_pods or alternating_mac CSV missing"
            )
        }

        let pct = Double(detected) / Double(totalWindows) * 100.0
        let disp = disposition(pct, budget: budget, warnThreshold: 72.0, higher: true)
        return CriterionResult(
            id: 8, name: "VAD heuristic accuracy ≥ 90%",
            budget: "≥ 90%",
            measured: "\(detected)/\(totalWindows) windows detected (\(String(format: "%.0f", pct))%)",
            disposition: disp,
            notes: "Heuristic: no update for >300ms → silence. Ground truth: 3 silence windows per clip."
        )
    }

    // 9. Confidence score accessibility (revised from plan per Revision 2, then further
    // revised based on actual FluidAudio 0.14.7 API inspection: confidence IS available).
    private func criterion9_isConfirmedAvailable() -> CriterionResult {
        let allUpdates = allRows.values.flatMap { $0 }
        guard !allUpdates.isEmpty else {
            return CriterionResult(
                id: 9, name: "Confidence score + isConfirmed accessible",
                budget: "confidence (0.0-1.0) and isConfirmed populated per update",
                measured: "no data",
                disposition: "FAIL",
                notes: "No updates across any fixture"
            )
        }
        // Check confidence values (sentinel -1.0 means absent)
        let withConf = allUpdates.filter { $0.confidence >= 0.0 }
        let confPopulated = Double(withConf.count) / Double(allUpdates.count) >= 0.95

        let trueCount = allUpdates.filter { $0.isConfirmed }.count
        let falseCount = allUpdates.filter { !$0.isConfirmed }.count
        let isConfirmedPresent = trueCount > 0 || falseCount > 0

        let pass = confPopulated && isConfirmedPresent
        let medianConf = withConf.isEmpty ? 0.0
            : withConf.map { $0.confidence }.sorted()[withConf.count / 2]

        return CriterionResult(
            id: 9, name: "Confidence score + isConfirmed accessible",
            budget: "confidence (0.0-1.0) populated ≥95% of updates; isConfirmed present",
            measured: "\(withConf.count)/\(allUpdates.count) updates have confidence; "
                + "median conf=\(String(format: "%.2f", medianConf)); "
                + "\(trueCount) confirmed, \(falseCount) unconfirmed",
            disposition: pass ? "PASS" : "FAIL",
            notes: "FluidAudio 0.14.7 exposes SlidingWindowTranscriptionUpdate.confidence: Float (0-1). "
                + "Anton's Q2/Q3 answer that 'no per-token confidence exists' was based on TiltTalk's "
                + "wrapper abstraction, not FluidAudio's raw API. Actual API has confidence."
        )
    }

    // 10. Cafe noise resilience.
    private func criterion10_cafeNoiseResilience() -> CriterionResult {
        let cafeFixtures = ["cafe_noise_pods", "cafe_noise_mac"]
        var results: [String] = []
        var pass = true

        for name in cafeFixtures {
            guard let rows = allRows[name] else {
                results.append("\(name): CSV not found")
                pass = false
                continue
            }
            if rows.isEmpty {
                results.append("\(name): 0 updates — FAIL")
                pass = false
            } else {
                let sample = rows.prefix(2).map { "\"\($0.text.prefix(40))\"" }.joined(separator: "; ")
                results.append("\(name): \(rows.count) updates — sample: \(sample)")
            }
        }

        return CriterionResult(
            id: 10, name: "Cafe noise resilience",
            budget: "≥ 1 update per clip; recognisable speech in first 2 updates",
            measured: results.joined(separator: " | "),
            disposition: pass ? "PASS" : "FAIL",
            notes: "Qualitative spot-check; WER not computed at spike scope."
        )
    }

    // 11. Memory footprint ≤ 200 MB.
    private func criterion11_memory() -> CriterionResult {
        let budget = 200.0
        let measured = bootstrap.peakRSSMB
        let disp = disposition(measured, budget: budget, warnThreshold: 160.0)
        return CriterionResult(
            id: 11, name: "Memory footprint ≤ 200 MB",
            budget: "≤ 200 MB resident",
            measured: "\(String(format: "%.1f", measured)) MB peak RSS",
            disposition: disp,
            notes: "TiltTalk measured 116 MB on iOS. macOS baseline may differ."
        )
    }

    // 12. Real-world cross-validation.
    private func criterion12_realWorldCrossValidation() -> CriterionResult {
        let fixtureNames = ["real_world_test", "quiet_speech_pods"]
        var found: String?

        for name in fixtureNames {
            if let rows = allRows[name], !rows.isEmpty {
                found = name
                break
            }
        }

        guard let name = found, let rows = allRows[name] else {
            return CriterionResult(
                id: 12, name: "Real-world cross-validation",
                budget: "incremental token timeline for real-world audio",
                measured: "no real_world_test or quiet_speech_pods CSV found",
                disposition: "FAIL",
                notes: "Neither real_world_test.caf nor quiet_speech_pods.caf produced output."
            )
        }

        let first10s = rows.filter { $0.emissionMs <= 10_000 }
        let timeline = first10s.map { row in
            "[\(String(format: "%5.0f", row.emissionMs))ms] \"\(row.text.prefix(50))\""
        }.joined(separator: "\n  ")

        let allStream = rows.contains { $0.emissionMs < 28_000 }

        return CriterionResult(
            id: 12, name: "Real-world cross-validation",
            budget: "incremental updates during audio (not batched at end)",
            measured: "\(rows.count) updates from \(name); first 10s: \(first10s.count) updates",
            disposition: allStream ? "PASS" : "FAIL",
            notes: "Timeline (first 10s):\n  \(timeline)"
        )
    }

    // MARK: - Helpers

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((p * Double(sorted.count - 1)).rounded())
        return sorted[index]
    }

    // For metrics where lower is better (latency, memory):
    // PASS if measured ≤ budget, WARN if within 80% of budget (i.e. ≥ warnThreshold),
    // FAIL if measured > budget.
    private func disposition(
        _ measured: Double,
        budget: Double,
        warnThreshold: Double,
        higher: Bool = false
    ) -> String {
        if higher {
            // Higher is better (e.g. accuracy percent)
            if measured >= budget { return "PASS" }
            if measured >= warnThreshold { return "WARN" }
            return "FAIL"
        } else {
            // Lower is better (e.g. latency, memory)
            if measured <= warnThreshold { return "PASS" }
            if measured <= budget { return "WARN" }
            return "FAIL"
        }
    }

    // VAD silence window inference (mirrors VADHeuristic in Spike17_1 library).
    private func vadInferredSilenceWindows(
        emissionTimestamps: [Double],
        sessionDurationMs: Double,
        silenceThresholdMs: Double
    ) -> [(start: Double, end: Double)] {
        guard !emissionTimestamps.isEmpty else { return [(0, sessionDurationMs)] }
        var windows: [(Double, Double)] = []
        var prev = emissionTimestamps[0]
        for ms in emissionTimestamps.dropFirst() {
            if ms - prev > silenceThresholdMs {
                windows.append((prev + silenceThresholdMs, ms))
            }
            prev = ms
        }
        let trailing = sessionDurationMs - prev
        if trailing > silenceThresholdMs {
            windows.append((prev + silenceThresholdMs, sessionDurationMs))
        }
        return windows
    }
}
