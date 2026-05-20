import Foundation

// Post-hoc VAD state reconstruction from a token event timeline.
// Used by Spike17_1Eval to evaluate criterion 8 (silence window detection).
// Not wired into real-time output — evaluation only.
enum VADHeuristic {
    // Returns an array of silence windows inferred by the heuristic rule:
    // "no new update for silenceThresholdMs means silence began at lastUpdateMs".
    // Input: sorted array of emission timestamps (ms since session start).
    // Output: [(inferredSilenceStartMs, inferredSilenceEndMs)] pairs.
    static func inferredSilenceWindows(
        emissionTimestamps: [Double],
        sessionDurationMs: Double,
        silenceThresholdMs: Double = 300.0
    ) -> [(start: Double, end: Double)] {
        guard !emissionTimestamps.isEmpty else {
            return [(0.0, sessionDurationMs)]
        }

        var windows: [(Double, Double)] = []
        var prevMs = emissionTimestamps[0]

        for ms in emissionTimestamps.dropFirst() {
            let gap = ms - prevMs
            if gap > silenceThresholdMs {
                // Silence inferred: started at prevMs + silenceThresholdMs
                let silStart = prevMs + silenceThresholdMs
                let silEnd = ms
                windows.append((silStart, silEnd))
            }
            prevMs = ms
        }

        // Trailing silence after last token
        let trailingGap = sessionDurationMs - prevMs
        if trailingGap > silenceThresholdMs {
            windows.append((prevMs + silenceThresholdMs, sessionDurationMs))
        }

        return windows
    }
}
