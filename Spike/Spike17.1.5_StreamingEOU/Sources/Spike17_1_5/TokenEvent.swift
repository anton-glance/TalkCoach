import Foundation

// One emission event from StreamingEouAsrManager, annotated with timing metadata
// for spike evaluation.
// confidence is -1.0 (sentinel) for partial (unconfirmed) updates — RNNT streaming
// does not expose per-chunk confidence. isConfirmed=true marks EOU boundaries and
// finish() return value, which serve as the utterance-level commit signal.
public struct TokenEvent: Sendable {
    public let updateIndex: Int
    public let emissionMs: Double
    public let gapFromPreviousMs: Double
    public let text: String
    public let isConfirmed: Bool
    public let confidence: Float

    public init(
        updateIndex: Int,
        emissionMs: Double,
        gapFromPreviousMs: Double,
        text: String,
        isConfirmed: Bool,
        confidence: Float
    ) {
        self.updateIndex = updateIndex
        self.emissionMs = emissionMs
        self.gapFromPreviousMs = gapFromPreviousMs
        self.text = text
        self.isConfirmed = isConfirmed
        self.confidence = confidence
    }
}
