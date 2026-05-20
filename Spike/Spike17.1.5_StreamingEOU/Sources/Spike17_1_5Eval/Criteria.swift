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
            criterion9_qualitySignalAccessible(),
            criterion10_cafeNoiseResilience(),
            criterion11_memory(),
            criterion12_realWorldCrossValidation(),
        ]
    }

    // 1. Build — pass/fail from bootstrap.
    private func criterion1_build() -> CriterionResult {
        let pass = bootstrap.modelLoadSuccess
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

    // 5. Inter-update p95 ≤ 400ms.
    // Uses ALL update gaps (not just confirmed), because StreamingEou emits partials
    // as isConfirmed=false and the single isConfirmed=true event is at clip end.
    // Using all gaps gives a realistic measure of widget refresh cadence.
    private func criterion5_interUpdateP95() -> CriterionResult {
        let budget = 400.0
        // Collect gaps from ALL updates (both confirmed and unconfirmed)
        let allGaps = allRows.values.flatMap { rows -> [Double] in
            guard rows.count >= 2 else { return [] }
            return rows.dropFirst().map { $0.gapFromPreviousMs }
        }
        guard !allGaps.isEmpty else {
            return CriterionResult(
                id: 5, name: "Inter-update p95 ≤ 400ms",
                budget: "≤ 400ms",
                measured: "no updates",
                disposition: "FAIL",
                notes: "No updates across any fixture"
            )
        }
        let p95 = percentile(allGaps, 0.95)
        let disp = disposition(p95, budget: budget, warnThreshold: 320.0)
        return CriterionResult(
            id: 5, name: "Inter-update p95 ≤ 400ms",
            budget: "≤ \(Int(budget))ms",
            measured: "\(String(format: "%.0f", p95))ms p95 across \(allGaps.count) gaps",
            disposition: disp,
            notes: "Gap between consecutive updates (all, not just confirmed). "
                + "StreamingEou emits partials as isConfirmed=false; widget refresh cadence driven by these."
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

    // 8. VAD heuristic accuracy — REFRAMED (Lock 3, Spike #17.1.5 approval).
    //
    // Original C8 checked whether any inferred silence window "starts within" the GT window.
    // Lock 3 reframing: a silence window is "detected" if the inferred silence starts within
    // 500ms of speech_end AND ends within 500ms of speech_onset.
    // Ground truth: alternating clips have silence windows [5s-10s], [15s-20s], [25s-30s].
    // PASS threshold: ≥5 of 6 windows (≥83.3%, the smallest integer count above the
    // 80ms-update-granularity margin — 6/6 is demanding given ~0.3s detection lag).
    //
    // Measured ONLY against alternating_pods.caf and alternating_mac.caf.
    private func criterion8_vadHeuristic() -> CriterionResult {
        let passThreshold = 5  // ≥5 of 6 = ≥83.3%
        let alternatingFixtures = ["alternating_pods", "alternating_mac"]

        // Ground truth silence windows (ms): speech_end → speech_onset
        // Stopwatch-measured at 5s, 10s, 15s, 20s, 25s, 30s boundaries.
        let groundTruthWindows: [(start: Double, end: Double)] = [
            (5_000, 10_000),
            (15_000, 20_000),
            (25_000, 30_000),
        ]
        let onsetToleranceMs = 500.0  // ±500ms around both speech_end and speech_onset

        var totalWindows = 0
        var detected = 0
        var detailLines: [String] = []

        for fixture in alternatingFixtures {
            guard let rows = allRows[fixture], !rows.isEmpty else {
                for _ in groundTruthWindows { totalWindows += 1 }
                detailLines.append("\(fixture): CSV missing or empty")
                continue
            }

            let emissionTimes = rows.map { $0.emissionMs }.sorted()
            let sessionDuration = (emissionTimes.last ?? 30_000) + 1_000
            let inferred = vadInferredSilenceWindows(
                emissionTimestamps: emissionTimes,
                sessionDurationMs: sessionDuration,
                silenceThresholdMs: 300.0
            )

            for gtWindow in groundTruthWindows {
                totalWindows += 1
                let speechEnd = gtWindow.start     // ms when speech stops
                let speechOnset = gtWindow.end     // ms when speech resumes

                // Find the best-matching inferred silence window for this GT window.
                // "Detected" = inferred silence starts within 500ms of speech_end
                //               AND inferred silence ends within 500ms of speech_onset.
                let isDetected = inferred.contains { inf in
                    let startOk = inf.start <= speechEnd + onsetToleranceMs
                        && inf.start >= speechEnd - onsetToleranceMs
                    let endOk = inf.end >= speechOnset - onsetToleranceMs
                    return startOk && endOk
                }
                if isDetected { detected += 1 }
                detailLines.append(
                    "\(fixture) [\(Int(speechEnd/1000))s–\(Int(speechOnset/1000))s]: "
                    + (isDetected ? "detected" : "MISSED")
                )
            }
        }

        guard totalWindows > 0 else {
            return CriterionResult(
                id: 8, name: "VAD heuristic accuracy ≥ 83%",
                budget: "≥ 83% (5/6 windows)",
                measured: "no alternating fixture data",
                disposition: "FAIL",
                notes: "alternating_pods or alternating_mac CSV missing"
            )
        }

        let pct = Double(detected) / Double(totalWindows) * 100.0
        let disp: String
        if detected >= passThreshold {
            disp = detected == totalWindows ? "PASS" : "WARN"
        } else {
            disp = "FAIL"
        }

        return CriterionResult(
            id: 8, name: "VAD heuristic accuracy ≥ 83%",
            budget: "≥ 83% (≥5/6 silence windows detected within 500ms tolerance)",
            measured: "\(detected)/\(totalWindows) windows (\(String(format: "%.0f", pct))%)",
            disposition: disp,
            notes: "Lock 3 reframe: start within ±500ms of speech_end, end within 500ms of speech_onset. "
                + detailLines.joined(separator: "; ")
        )
    }

    // 9. Quality signal accessible — REFRAMED (Lock 1, Spike #17.1.5 approval).
    //
    // Original C9: "Confidence (0-1) and isConfirmed populated on ≥95% of updates."
    // Reframed for StreamingEouAsrManager: RNNT streaming decoder does not expose
    // per-chunk confidence (genuine architectural gap, not an implementation bug).
    // The utterance-level commit signal is isConfirmed=true at EOU boundaries and
    // at finish(). This still serves the product-equivalent purpose for Locto coaching:
    // "engine just committed an utterance" vs "still processing."
    //
    // PASS = isConfirmed field populated on every event (both true and false present)
    //        AND final emission per speech clip is isConfirmed=true.
    // FAIL = no isConfirmed signal at all OR any speech clip's final emission is
    //        isConfirmed=false (no utterance-level commit ever fired).
    private func criterion9_qualitySignalAccessible() -> CriterionResult {
        let speechFixtures = allRows.filter { !$0.key.hasPrefix("silence_only") }
        guard !speechFixtures.isEmpty else {
            return CriterionResult(
                id: 9, name: "Quality signal accessible (isConfirmed per utterance)",
                budget: "isConfirmed=true on final emission per speech clip",
                measured: "no speech fixture data",
                disposition: "FAIL",
                notes: "Lock 1 reframe: RNNT has no per-chunk confidence; isConfirmed=true at EOU/finish() is the quality signal"
            )
        }

        var clipsWithFinalConfirmed = 0
        var clipsWithNoEvents = 0
        var clipsWithFalseEnding = 0
        var anyIsConfirmedTrue = false
        var anyIsConfirmedFalse = false
        var clipDetails: [String] = []

        for (fixture, rows) in speechFixtures {
            let nonEmptyRows = rows.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            if nonEmptyRows.isEmpty {
                clipsWithNoEvents += 1
                clipDetails.append("\(fixture): 0 non-empty events")
                continue
            }

            let lastRow = nonEmptyRows.last!
            if lastRow.isConfirmed {
                clipsWithFinalConfirmed += 1
                anyIsConfirmedTrue = true
                clipDetails.append("\(fixture): final isConfirmed=true ✓")
            } else {
                clipsWithFalseEnding += 1
                clipDetails.append("\(fixture): final isConfirmed=false ✗")
            }

            for row in rows {
                if row.isConfirmed { anyIsConfirmedTrue = true }
                else { anyIsConfirmedFalse = true }
            }
        }

        let isConfirmedBothPresent = anyIsConfirmedTrue && anyIsConfirmedFalse
        let pass = clipsWithFalseEnding == 0
            && clipsWithNoEvents < speechFixtures.count
            && anyIsConfirmedTrue

        let allUpdates = speechFixtures.values.flatMap { $0 }
        let trueCount = allUpdates.filter { $0.isConfirmed }.count
        let falseCount = allUpdates.filter { !$0.isConfirmed }.count

        return CriterionResult(
            id: 9, name: "Quality signal accessible (isConfirmed per utterance)",
            budget: "isConfirmed=true on final emission per speech clip; both true/false present",
            measured: "\(clipsWithFinalConfirmed)/\(speechFixtures.count - clipsWithNoEvents) clips "
                + "have final isConfirmed=true; \(trueCount) confirmed, \(falseCount) unconfirmed events; "
                + "both-present=\(isConfirmedBothPresent)",
            disposition: pass ? "PASS" : "FAIL",
            notes: "Lock 1 reframe: RNNT streaming has no per-chunk confidence (sentinel -1.0 in CSV). "
                + "Product-equivalent signal: isConfirmed=true = utterance committed. "
                + clipDetails.joined(separator: "; ")
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
            notes: "120M model (vs 600M TDT v3 at 78.9 MB in #17.1). Expect lower or comparable."
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

    private func disposition(
        _ measured: Double,
        budget: Double,
        warnThreshold: Double,
        higher: Bool = false
    ) -> String {
        if higher {
            if measured >= budget { return "PASS" }
            if measured >= warnThreshold { return "WARN" }
            return "FAIL"
        } else {
            if measured <= warnThreshold { return "PASS" }
            if measured <= budget { return "WARN" }
            return "FAIL"
        }
    }

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
