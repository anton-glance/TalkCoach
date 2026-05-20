import Foundation

func buildSummary(
    bootstrap: BootstrapResult,
    clips: [ClipResult],
    allRows: [String: [CSVRow]],
    criteria: [CriterionResult]
) -> Summary {
    // Overall verdict: all PASS → PASS; any FAIL → FAIL; otherwise NEEDS_TUNING.
    let hasFail = criteria.contains { $0.disposition == "FAIL" }
    let hasWarn = criteria.contains { $0.disposition == "WARN" }
    let verdict = hasFail ? "FAIL" : (hasWarn ? "NEEDS_TUNING" : "PASS")

    var reasons: [String] = []
    for c in criteria where c.disposition != "PASS" {
        reasons.append("C\(c.id) \(c.name): \(c.disposition) — \(c.measured)")
    }
    if reasons.isEmpty { reasons = ["all 12 criteria passed"] }

    // Aggregate latency metrics
    let speechClips = clips.filter { !$0.fixture.hasPrefix("silence_only") }
    let firstUpdateTimes = speechClips.compactMap { $0.firstUpdateEmissionMs }
    let medianFirst = firstUpdateTimes.isEmpty ? 0.0 : percentile(firstUpdateTimes, 0.50)

    let allGaps = clips.flatMap { $0.confirmedUpdateGapsMs }
    let p95gap = allGaps.isEmpty ? 0.0 : percentile(allGaps, 0.95)

    let anyRows = allRows.values.flatMap { $0 }
    let v9IsConfirmed = !anyRows.isEmpty
    let v9Confidence = anyRows.contains { $0.confidence >= 0.0 }

    let formatter = ISO8601DateFormatter()
    return Summary(
        verdict: verdict,
        verdictReasons: reasons,
        criteria: criteria,
        aggregateMedianFirstUpdateMs: medianFirst,
        aggregateP95GapMs: p95gap,
        bootstrapPeakRSSMB: bootstrap.peakRSSMB,
        bootstrapModelLoadSuccess: bootstrap.modelLoadSuccess,
        v7NativeVADAvailable: false,
        v8NativeVADExposedViaVADSubmodule: true,  // FluidAudio has VAD module; not in SlidingWindow path
        v9ConfidenceAvailable: v9Confidence,
        v9IsConfirmedAvailable: v9IsConfirmed,
        generatedAt: formatter.string(from: Date())
    )
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = Int((p * Double(sorted.count - 1)).rounded())
    return sorted[index]
}
