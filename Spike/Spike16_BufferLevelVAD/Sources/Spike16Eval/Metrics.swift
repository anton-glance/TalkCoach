import Foundation

let kBufferMS = 10  // each CSV row = 10ms buffer

// MARK: - 300ms closing filter

/// Bridges any false gap shorter than 300ms to true. Returns array of bool in same order as input rows.
func apply300msSmoothing(activeFlags: [Bool]) -> [Bool] {
    guard !activeFlags.isEmpty else { return [] }
    var result = activeFlags
    var i = 0
    while i < result.count {
        if !result[i] {
            var j = i
            while j < result.count && !result[j] { j += 1 }
            let durationMS = (j - i) * kBufferMS
            if durationMS < 300 {
                for k in i..<j { result[k] = true }
            }
            i = j
        } else {
            i += 1
        }
    }
    return result
}

// MARK: - Voice-on/off transitions

struct Transition {
    let timestampMS: Int
    let toActive: Bool
}

func buildTransitions(rows: [CSVRow]) -> [Transition] {
    var transitions: [Transition] = []
    for i in 1..<rows.count {
        if rows[i].isVoiceActive != rows[i-1].isVoiceActive {
            transitions.append(Transition(timestampMS: rows[i].timestampMS,
                                          toActive: rows[i].isVoiceActive))
        }
    }
    return transitions
}

// MARK: - Onset latency

/// Returns latency in ms for each speech_onset event. Negative values indicate early detection.
/// Search strategy: first look for a transition within ±500ms of the event (handles early detection
/// due to ±500ms ground truth accuracy). Fall back to next transition after the event, capped at 500ms.
func computeOnsetLatencies(eventSeconds: [Double], transitions: [Transition]) -> [Int] {
    let onsetTransitions = transitions.filter { $0.toActive }
    return eventSeconds.map { eventSec in
        let eventMS = Int(eventSec * 1000.0)
        // Search in proximity window ±500ms
        let window = onsetTransitions.filter { abs($0.timestampMS - eventMS) <= 500 }
        if let t = window.min(by: { abs($0.timestampMS - eventMS) < abs($1.timestampMS - eventMS) }) {
            return t.timestampMS - eventMS
        }
        // Late detection: next onset transition after event, capped at 500ms
        if let t = onsetTransitions.first(where: { $0.timestampMS > eventMS + 500 }) {
            return min(t.timestampMS - eventMS, 500)
        }
        return 500  // no transition found in clip
    }
}

// MARK: - End latency

/// Returns latency in ms for each speech_end event that has enough room after it (≥ 1000ms before clip end).
/// Search strategy: ±500ms proximity window, then fallback capped at 2000ms.
func computeEndLatencies(eventSeconds: [Double], transitions: [Transition], clipDurationMS: Int) -> [Int] {
    let endTransitions = transitions.filter { !$0.toActive }
    return eventSeconds.compactMap { eventSec in
        let eventMS = Int(eventSec * 1000.0)
        guard clipDurationMS - eventMS >= 1000 else { return nil }
        // Search in proximity window ±500ms
        let window = endTransitions.filter { abs($0.timestampMS - eventMS) <= 500 }
        if let t = window.min(by: { abs($0.timestampMS - eventMS) < abs($1.timestampMS - eventMS) }) {
            return t.timestampMS - eventMS
        }
        // Late detection: next offset transition after event, capped at 2000ms
        if let t = endTransitions.first(where: { $0.timestampMS > eventMS + 500 }) {
            return min(t.timestampMS - eventMS, 2000)
        }
        return 2000
    }
}

// MARK: - False negative rate (speech intervals, with 300ms smoothing)

struct FNResult {
    let start_ms: Int
    let end_ms: Int
    let falseNegativeDuration_ms: Int
    let falseNegativeRate_pct: Double
}

func computeFalseNegativeRate(rows: [CSVRow], startMS: Int, endMS: Int) -> FNResult {
    let slice = rows.filter { $0.timestampMS > startMS && $0.timestampMS <= endMS }
    guard !slice.isEmpty else {
        return FNResult(start_ms: startMS, end_ms: endMS, falseNegativeDuration_ms: 0,
                        falseNegativeRate_pct: 0.0)
    }
    let smoothed = apply300msSmoothing(activeFlags: slice.map { $0.isVoiceActive })
    let fnCount = smoothed.filter { !$0 }.count
    let fnDurationMS = fnCount * kBufferMS
    let totalDurationMS = slice.count * kBufferMS
    let rate = totalDurationMS > 0 ? Double(fnDurationMS) / Double(totalDurationMS) * 100.0 : 0.0
    return FNResult(start_ms: startMS, end_ms: endMS, falseNegativeDuration_ms: fnDurationMS,
                    falseNegativeRate_pct: rate)
}

// MARK: - False positive duration (silence intervals, no smoothing)

func computeFalsePositiveDuration(rows: [CSVRow], startMS: Int, endMS: Int) -> Int {
    let slice = rows.filter { $0.timestampMS > startMS && $0.timestampMS <= endMS }
    return slice.filter { $0.isVoiceActive }.count * kBufferMS
}

// MARK: - Distractor interval (speech expected throughout, 300ms smoothing applied)

struct DistractorResult {
    let eventType: String
    let start_ms: Int
    let end_ms: Int
    let incorrectStateDuration_ms: Int
    let incorrectStateRate_pct: Double
    let latencyToCorrect_ms: Int
}

func computeDistractorInterval(rows: [CSVRow], transitions: [Transition],
                                eventType: String, startMS: Int, endMS: Int) -> DistractorResult {
    let slice = rows.filter { $0.timestampMS > startMS && $0.timestampMS <= endMS }
    let smoothed = apply300msSmoothing(activeFlags: slice.map { $0.isVoiceActive })
    let incorrectCount = smoothed.filter { !$0 }.count
    let incorrectMS = incorrectCount * kBufferMS
    let totalMS = max(slice.count * kBufferMS, 1)
    let rate = Double(incorrectMS) / Double(totalMS) * 100.0

    // Latency-to-correct: time from endMS to next sustained voice-on transition
    let onsetTransitions = transitions.filter { $0.toActive && $0.timestampMS >= endMS }
    let latency: Int
    if let t = onsetTransitions.first {
        latency = t.timestampMS - endMS
    } else {
        latency = -1  // signal: no re-onset found (speech may not return before clip end)
    }

    return DistractorResult(eventType: eventType, start_ms: startMS, end_ms: endMS,
                             incorrectStateDuration_ms: incorrectMS,
                             incorrectStateRate_pct: rate, latencyToCorrect_ms: latency)
}

// MARK: - Calibration fallback observation

func extractCalibrationInfo(rows: [CSVRow]) -> (fallbackUsed: Bool, effectiveThresholdDB: Float) {
    let fallbackUsed = rows.contains { $0.calibrationState == "fallback" }
    // Threshold at the moment calibration resolves (first row that is NOT "calibrating")
    let resolved = rows.first { $0.calibrationState != "calibrating" }
    return (fallbackUsed, resolved?.thresholdDB ?? -40.0)
}
