import Foundation

/// Sliding-window, VAD-aware words-per-minute calculator with EMA smoothing.
public struct WPMCalculator: Sendable {
    public init(windowSize: TimeInterval, emaAlpha: Double) {
        fatalError("Not implemented")
    }

    public mutating func addWord(_ word: TimestampedWord) {
        fatalError("Not implemented")
    }

    public mutating func addVADEvent(_ event: VADEvent) {
        fatalError("Not implemented")
    }

    public mutating func wpm(at timestamp: TimeInterval) -> WPMSample {
        fatalError("Not implemented")
    }

    public var sessionAverageWPM: Double {
        fatalError("Not implemented")
    }

    /// Batch convenience for spike/test usage. Default sampleInterval matches
    /// production widget update rate (3.0s per product spec).
    public func processAll(
        words: [TimestampedWord],
        vadEvents: [VADEvent],
        sampleInterval: TimeInterval = 3.0
    ) -> [WPMSample] {
        fatalError("Not implemented")
    }
}
