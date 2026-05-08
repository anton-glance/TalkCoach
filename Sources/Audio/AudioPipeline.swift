import AVFAudio
import os
import OSLog

// MARK: - Error type

enum AudioPipelineError: Error {
    case vpioConfigurationFailed(underlying: Error)
    case engineStartFailed(underlying: Error)
}

// MARK: - Sendable buffer value type

nonisolated struct CapturedAudioBuffer: Sendable {
    let frameLength: AVAudioFrameCount
    let sampleRate: Double
    let channelCount: UInt32
    let sampleTime: Int64
    let hostTime: UInt64
    let samples: [[Float]]
}

// MARK: - Tap closure factory (nonisolated — load-bearing under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor)

nonisolated func makeTapBlock(
    continuation: AsyncStream<CapturedAudioBuffer>.Continuation
) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
    { buffer, time in
        let frameLength = buffer.frameLength
        let channelCount = buffer.format.channelCount

        var channels: [[Float]] = []
        channels.reserveCapacity(Int(channelCount))

        if let floatData = buffer.floatChannelData {
            for ch in 0..<Int(channelCount) {
                let ptr = floatData[ch]
                let channelSamples = Array(UnsafeBufferPointer(start: ptr, count: Int(frameLength)))
                channels.append(channelSamples)
            }
        }

        let captured = CapturedAudioBuffer(
            frameLength: frameLength,
            sampleRate: buffer.format.sampleRate,
            channelCount: channelCount,
            sampleTime: time.sampleTime,
            hostTime: time.hostTime,
            samples: channels
        )
        continuation.yield(captured)
    }
}

// MARK: - AudioPipeline

final class AudioPipeline {
    private(set) var isStarted: Bool = false
    private(set) var lastRecoveryDuration: TimeInterval?
    let bufferStream: AsyncStream<CapturedAudioBuffer>

    private let provider: any AudioEngineProvider
    private let continuation: AsyncStream<CapturedAudioBuffer>.Continuation
    private var isStopped = false
    nonisolated(unsafe) private var configChangeObserver: (any NSObjectProtocol)?

    init(provider: any AudioEngineProvider = SystemAudioEngineProvider()) {
        self.provider = provider
        var cont: AsyncStream<CapturedAudioBuffer>.Continuation!
        self.bufferStream = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { cont = $0 }
        self.continuation = cont
    }

    deinit {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        continuation.finish()
    }

    func start() throws {
        // Stub — implementation in next commit
    }

    func stop() {
        // Stub — implementation in next commit
    }

    func recover() {
        // Stub — implementation in next commit
    }
}
