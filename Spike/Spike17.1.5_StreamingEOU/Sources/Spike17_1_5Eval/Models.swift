import Foundation

// MARK: - Raw CSV row

struct CSVRow {
    let updateIndex: Int
    let emissionMs: Double
    let gapFromPreviousMs: Double
    let text: String
    let isConfirmed: Bool
    let confidence: Double  // per-update confidence score (0.0-1.0); nil sentinel: -1.0
}

// MARK: - Manifest event

struct ManifestEvent {
    let clip: String       // e.g. "alternating"
    let mic: String        // "pods" or "mac"
    let eventType: String  // "speech_onset", "speech_end", "silence_start", "silence_end", ...
    let eventSeconds: Double?
    let notes: String
}

// MARK: - Per-clip result

struct ClipResult: Codable {
    let fixture: String     // e.g. "alternating_pods"
    let clip: String        // e.g. "alternating"
    let mic: String         // e.g. "pods"
    let totalUpdateCount: Int
    let confirmedUpdateCount: Int
    let firstUpdateEmissionMs: Double?
    let firstConfirmedEmissionMs: Double?
    let audioDurationMs: Double  // estimated from last emission + margin
    // Whether first update arrived before the audio finished feeding.
    let firstUpdateBeforeAudioEnd: Bool
    // Gaps between confirmed updates (for latency percentile computation).
    let confirmedUpdateGapsMs: [Double]
    // Empty for silence_only clips; populated for all others.
    let sampleTexts: [String]  // first 3 update texts for spot-check
}

// MARK: - Per-criterion result

struct CriterionResult: Codable {
    let id: Int
    let name: String
    let budget: String
    let measured: String
    let disposition: String  // "PASS", "WARN", "FAIL", "SKIP"
    let notes: String
}

// MARK: - Summary

struct Summary: Codable {
    let verdict: String              // "PASS", "NEEDS_TUNING", "FAIL"
    let verdictReasons: [String]
    let criteria: [CriterionResult]
    let aggregateMedianFirstUpdateMs: Double
    let aggregateP95GapMs: Double
    let bootstrapPeakRSSMB: Double
    let bootstrapModelLoadSuccess: Bool
    let v7NativeVADAvailable: Bool   // false — FluidAudio has no native VAD signal
    let v8NativeVADExposedViaVADSubmodule: Bool  // FluidAudio has a VAD submodule; not integrated in SlidingWindow
    let v9ConfidenceAvailable: Bool  // true — SlidingWindowTranscriptionUpdate.confidence is 0.0-1.0
    let v9IsConfirmedAvailable: Bool
    let generatedAt: String
}

// MARK: - Bootstrap result (mirror of CLI struct for JSON parsing)

struct BootstrapResult: Codable {
    let modelLoadSuccess: Bool
    let loadDurationMs: Double
    let peakRSSMB: Double
    let errorDescription: String?
}
