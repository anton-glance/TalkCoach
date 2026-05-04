@preconcurrency import AVFoundation
import Speech

public func makeTapHandler(
    rmsAccumulator: RMSAccumulator,
    bufferRelay: BufferRelay
) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
    { buffer, _ in
        rmsAccumulator.processBuffer(buffer)
        bufferRelay.enqueue(buffer)
    }
}

public final class BufferRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []

    public init() {}

    public func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard let copy = copyBuffer(buffer) else { return }
        lock.lock()
        buffers.append(copy)
        lock.unlock()
    }

    public func drainAll() -> [AVAudioPCMBuffer] {
        lock.lock()
        let result = buffers
        buffers = []
        lock.unlock()
        return result
    }

    private func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        copy.frameLength = source.frameLength
        guard let srcData = source.floatChannelData,
            let dstData = copy.floatChannelData
        else { return nil }
        let channels = Int(source.format.channelCount)
        let frames = Int(source.frameLength)
        for ch in 0..<channels {
            dstData[ch].update(from: srcData[ch], count: frames)
        }
        return copy
    }
}
