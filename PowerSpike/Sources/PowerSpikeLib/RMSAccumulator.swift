import AVFoundation
import Foundation

public final class RMSAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var sumOfSquares: Double = 0
    private var sampleCount: Int = 0

    public init() {}

    public func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var localSum: Double = 0
        let samples = channelData[0]
        for i in 0..<frameCount {
            let s = Double(samples[i])
            localSum += s * s
        }

        lock.lock()
        sumOfSquares += localSum
        sampleCount += frameCount
        lock.unlock()
    }

    public func consumeRMS() -> Double {
        lock.lock()
        let sum = sumOfSquares
        let count = sampleCount
        sumOfSquares = 0
        sampleCount = 0
        lock.unlock()

        guard count > 0 else { return 0 }
        return (sum / Double(count)).squareRoot()
    }
}
