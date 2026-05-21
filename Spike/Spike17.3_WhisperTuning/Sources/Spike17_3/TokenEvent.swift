import Foundation

/// A single transcription update emitted by StreamingWhisperVoiceDetector.
/// Fix 4: audioSamplePositionMs added — audio time at which inference fired,
/// computed as (totalSamplesProcessed * 1000 / sampleRate). Comparable to
/// manifest event_seconds. emissionMs is wall-clock from session start (still
/// emitted for C5 gap measurement, but NOT used for C8 boundary comparison).
public struct TokenEvent: Sendable {
    public let updateIndex:            Int
    public let emissionMs:             Double  // wall-clock ms from session start
    public let gapFromPreviousMs:      Double
    public let audioSamplePositionMs:  Int     // audio-domain ms (Fix 4)
    public let text:                   String
    public let isConfirmed:            Bool
    public let confidence:             Float

    public init(
        updateIndex:            Int,
        emissionMs:             Double,
        gapFromPreviousMs:      Double,
        audioSamplePositionMs:  Int,
        text:                   String,
        isConfirmed:            Bool,
        confidence:             Float
    ) {
        self.updateIndex            = updateIndex
        self.emissionMs             = emissionMs
        self.gapFromPreviousMs      = gapFromPreviousMs
        self.audioSamplePositionMs  = audioSamplePositionMs
        self.text                   = text
        self.isConfirmed            = isConfirmed
        self.confidence             = confidence
    }
}
