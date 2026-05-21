import Foundation

/// A text update emitted by StreamingWhisperVoiceDetector.
/// Schema matches #17.1 and #17.1.5 for eval reuse.
public struct TokenEvent: Sendable {
    public let updateIndex: Int
    public let emissionMs: Double       // ms since session start
    public let gapFromPreviousMs: Double
    public let text: String
    public let isConfirmed: Bool        // true = EOS / VAD silence confirmed
    public let confidence: Float        // median log_prob across segment tokens (0–1); -1 if unavailable
}
