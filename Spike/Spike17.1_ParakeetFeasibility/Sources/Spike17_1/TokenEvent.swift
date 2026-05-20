import Foundation

// One SlidingWindowTranscriptionUpdate from FluidAudio's SlidingWindowAsrManager,
// annotated with timing metadata for spike evaluation.
public struct TokenEvent: Sendable {
    public let updateIndex: Int
    public let emissionMs: Double
    public let gapFromPreviousMs: Double
    public let text: String
    public let isConfirmed: Bool
    // Per-update confidence from SlidingWindowTranscriptionUpdate.confidence (0.0-1.0).
    // TiltTalk's abstraction hid this; FluidAudio 0.14.7's raw API exposes it.
    public let confidence: Float
}
