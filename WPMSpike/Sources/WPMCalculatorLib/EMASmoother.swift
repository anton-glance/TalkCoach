import Foundation

/// Exponential moving average filter.
///
/// Formula: `output = alpha * value + (1 - alpha) * previousOutput`.
/// First call returns the input value directly (no history to smooth against).
public struct EMASmoother: Sendable {
    private let alpha: Double
    private var previousOutput: Double?

    public init(alpha: Double) {
        precondition(alpha > 0 && alpha <= 1, "Alpha must be in (0, 1]")
        self.alpha = alpha
    }

    public mutating func smooth(_ value: Double) -> Double {
        guard let previous = previousOutput else {
            previousOutput = value
            return value
        }
        let output = alpha * value + (1 - alpha) * previous
        previousOutput = output
        return output
    }

    public mutating func reset() {
        previousOutput = nil
    }
}
