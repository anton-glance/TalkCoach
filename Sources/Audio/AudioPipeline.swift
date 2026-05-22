import AVFAudio
import CoreAudio
import os
import OSLog

private let logger = Logger.audio
private let signposter = OSSignposter(logger: logger)

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
            // swiftlint:disable:next identifier_name
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

/// Owns an `AVAudioEngine` input tap and delivers `CapturedAudioBuffer` values
/// via `AsyncStream`. Copied from the canonical pattern in
/// `MicTapTightenSpike/AudioTapBridge.swift` (Spike #4 Phase 2, Session 022).
/// Composes with `MicMonitor`'s log-and-continue pattern: if the default device
/// disappears during recovery, the pipeline logs and awaits the next config-change.
final class AudioPipeline {
    private(set) var isStarted: Bool = false
    private(set) var lastRecoveryDuration: TimeInterval?
    var onRecoveryBegan: (() -> Void)?
    var onRecoveryEnded: (() -> Void)?
    // AsyncStream is single-consumer per SE-0314. Recreated on each start() so each
    // session's feedTask iterator operates on a fresh stream. nonisolated(unsafe) because
    // AudioPipelineBufferProvider.bufferStream() may read this from non-MainActor contexts;
    // the write in start() happens-before the read via the SessionCoordinator wiring sequence.
    nonisolated(unsafe) private(set) var bufferStream: AsyncStream<CapturedAudioBuffer>
    nonisolated(unsafe) private var continuation: AsyncStream<CapturedAudioBuffer>.Continuation

    private let provider: any AudioEngineProvider
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
        guard !isStarted else { return }

        // Recreate stream + continuation each session (see property comment).
        var cont: AsyncStream<CapturedAudioBuffer>.Continuation!
        self.bufferStream = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { cont = $0 }
        self.continuation = cont

        do {
            try provider.setVoiceProcessingEnabled(false)
        } catch {
            throw AudioPipelineError.vpioConfigurationFailed(underlying: error)
        }

        provider.installTap(
            bufferSize: 0,
            format: nil,
            block: makeTapBlock(continuation: continuation)
        )

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recover()
            }
        }

        provider.prepare()

        do {
            try provider.start()
        } catch {
            provider.removeTap()
            if let observer = configChangeObserver {
                NotificationCenter.default.removeObserver(observer)
                configChangeObserver = nil
            }
            throw AudioPipelineError.engineStartFailed(underlying: error)
        }

        logInputDeviceIdentity()
        isStarted = true
    }

    func stop() {
        guard isStarted else { return }

        provider.removeTap()
        provider.stop()

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        // Finish current session's stream so its iterator terminates cleanly.
        // The next start() will recreate both stream and continuation.
        continuation.finish()
        isStarted = false
    }

    private func logInputDeviceIdentity() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            logger.warning("input-device: could not determine default input device")
            return
        }

        let name = audioStringProperty(deviceID, selector: kAudioObjectPropertyName)
        let uid  = audioStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)

        var nominalRate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &rateAddr, 0, nil, &rateSize, &nominalRate)

        var volume: Float32 = 0
        var volSize = UInt32(MemoryLayout<Float32>.size)
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let volOK = AudioObjectGetPropertyData(deviceID, &volAddr, 0, nil, &volSize, &volume) == noErr
        let volStr = volOK ? String(format: "%.3f", volume) : "n/a"

        logger.info("input-device: id=\(deviceID, privacy: .public) name=\(name, privacy: .public) uid=\(uid, privacy: .public) rate=\(nominalRate, privacy: .public) inputVol=\(volStr, privacy: .public)")
    }

    // Core Audio returns a new-retained CFStringRef (pointer value) via outData.
    // Capture it as Int (same size as pointer on 64-bit) to avoid ARC touching
    // uninitialized reference storage, then take ownership via Unmanaged.fromOpaque.
    private func audioStringProperty(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var ptrValue: Int = 0
        var propSize = UInt32(MemoryLayout<Int>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &propSize, &ptrValue)
        guard status == noErr, ptrValue != 0,
              let rawPtr = UnsafeRawPointer(bitPattern: ptrValue) else { return "unknown" }
        return Unmanaged<CFString>.fromOpaque(rawPtr).takeRetainedValue() as String
    }

    func recover() {
        guard isStarted else { return }
        onRecoveryBegan?()
        let start = CFAbsoluteTimeGetCurrent()
        let interval = signposter.beginInterval("AudioRecovery")

        provider.stop()
        provider.removeTap()

        do {
            try provider.setVoiceProcessingEnabled(false)
        } catch {
            logger.warning("VPIO re-disable failed during recovery: \(error.localizedDescription)")
        }

        provider.installTap(
            bufferSize: 0,
            format: nil,
            block: makeTapBlock(continuation: continuation)
        )

        provider.prepare()

        do {
            try provider.start()
        } catch {
            logger.warning("Engine restart failed during recovery: \(error.localizedDescription)")
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        lastRecoveryDuration = elapsed
        signposter.endInterval("AudioRecovery", interval)
        logger.info("Recovered in \(Int(elapsed * 1000))ms")
        onRecoveryEnded?()
    }
}
