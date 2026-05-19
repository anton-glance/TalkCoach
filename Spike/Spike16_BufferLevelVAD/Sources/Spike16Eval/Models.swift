import Foundation

// MARK: - Per-clip output models

struct SpeechInterval: Codable {
    let start_ms: Int
    let end_ms: Int
    let falseNegativeRate_pct: Double
    let falseNegativeDuration_ms: Int
}

struct SilenceInterval: Codable {
    let start_ms: Int
    let end_ms: Int
    let falsePositiveDuration_ms: Int
}

struct DistractorInterval: Codable {
    let type: String
    let start_ms: Int
    let end_ms: Int
    let incorrectStateDuration_ms: Int
    let incorrectStateRate_pct: Double
    let latencyToCorrect_ms: Int  // ms for flag to return to correct after distractor ends; -1 if not applicable
}

struct ClipResult: Codable {
    let clip: String
    let mic: String
    let calibrationFallbackUsed: Bool
    let effectiveThresholdDB_at_calibration: Float
    let onsetLatencies_ms: [Int]
    let onsetLatency_median_ms: Int
    let onsetLatency_p95_ms: Int
    let onsetLatency_max_ms: Int
    let endLatencies_ms: [Int]
    let endLatency_median_ms: Int
    let endLatency_p95_ms: Int
    let endLatency_max_ms: Int
    let speechIntervals: [SpeechInterval]
    let silenceIntervals: [SilenceInterval]
    let distractorIntervals: [DistractorInterval]
    let distractorSilenceFalsePositive_ms: Int
}

// MARK: - Summary models

struct CalibrationCheck: Codable {
    let clip: String
    let expected: Bool
    let actual: Bool
    let pass: Bool
}

struct Aggregate: Codable {
    let onset_latency_median_ms: Int
    let onset_latency_p95_ms: Int
    let onset_latency_max_ms: Int
    let end_latency_median_ms: Int
    let end_latency_p95_ms: Int
    let end_latency_max_ms: Int
    let silence_only_pods_fp_ms: Int
    let silence_only_mac_fp_ms: Int
    let speech_fn_max_pct: Double
    let distractor_max_incorrect_pct: Double
    let calibration_fallback_correctness: [CalibrationCheck]
    let fallback_fn_max_pct: Double
}

struct VerdictReason: Codable {
    let criterion: String
    let expected: String
    let actual: String
    let disposition: String
}

struct Summary: Codable {
    let clips: [ClipResult]
    let aggregate: Aggregate
    let verdict: String
    let verdictReasons: [VerdictReason]
}
