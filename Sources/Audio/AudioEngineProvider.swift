import AVFAudio

protocol AudioEngineProvider: AnyObject {
    var isVoiceProcessingEnabled: Bool { get }
    func setVoiceProcessingEnabled(_ enabled: Bool) throws
    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    )
    func removeTap()
    func prepare()
    func start() throws
    func stop()
}

// MARK: - Production Implementation

final class SystemAudioEngineProvider: AudioEngineProvider {
    private let engine = AVAudioEngine()

    var isVoiceProcessingEnabled: Bool {
        engine.inputNode.isVoiceProcessingEnabled
    }

    func setVoiceProcessingEnabled(_ enabled: Bool) throws {
        try engine.inputNode.setVoiceProcessingEnabled(enabled)
    }

    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: bufferSize,
            format: format,
            block: block
        )
    }

    func removeTap() {
        engine.inputNode.removeTap(onBus: 0)
    }

    func prepare() {
        engine.prepare()
    }

    func start() throws {
        try engine.start()
    }

    func stop() {
        engine.stop()
    }
}
