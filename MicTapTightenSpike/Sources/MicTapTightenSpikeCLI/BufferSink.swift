import Foundation

actor BufferSink {
    private(set) var bufferCount: Int = 0
    private(set) var lastSampleRate: Double = 0
    private(set) var lastChannelCount: UInt32 = 0
    private(set) var lastSampleTime: Int64 = 0
    private(set) var lastHostTime: UInt64 = 0
    private(set) var totalSamplesCopied: Int = 0

    func process(_ buffer: CapturedAudioBuffer) {
        bufferCount += 1
        lastSampleRate = buffer.sampleRate
        lastChannelCount = buffer.channelCount
        lastSampleTime = buffer.sampleTime
        lastHostTime = buffer.hostTime

        let expectedSamples = Int(buffer.frameLength) * Int(buffer.channelCount)
        let actualSamples = buffer.samples.reduce(0) { $0 + $1.count }
        assert(
            actualSamples == expectedSamples,
            "Sample count mismatch: expected \(expectedSamples), got \(actualSamples)"
        )
        totalSamplesCopied += actualSamples
    }

    func processWithDelay(_ buffer: CapturedAudioBuffer, delayMs: UInt64) async {
        try? await Task.sleep(for: .milliseconds(delayMs))
        process(buffer)
    }

    func snapshot() -> SinkSnapshot {
        SinkSnapshot(
            bufferCount: bufferCount,
            lastSampleRate: lastSampleRate,
            lastChannelCount: lastChannelCount,
            lastSampleTime: lastSampleTime,
            lastHostTime: lastHostTime,
            totalSamplesCopied: totalSamplesCopied
        )
    }

    func reset() {
        bufferCount = 0
        lastSampleRate = 0
        lastChannelCount = 0
        lastSampleTime = 0
        lastHostTime = 0
        totalSamplesCopied = 0
    }
}

nonisolated struct SinkSnapshot: Sendable {
    let bufferCount: Int
    let lastSampleRate: Double
    let lastChannelCount: UInt32
    let lastSampleTime: Int64
    let lastHostTime: UInt64
    let totalSamplesCopied: Int
}
