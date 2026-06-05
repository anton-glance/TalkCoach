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

/// Owns an `AVAudioEngine` input tap and delivers `CapturedAudioBuffer` values via two streams:
///
/// - `mediumStream`: session-lifetime stream. Created fresh on each `start()`, finished on `stop()`.
///   Survives `switchDevice()` so consumers (VAD gate, Parakeet backend) see only a brief buffer
///   gap during a device switch, never a stream termination.
///
/// - Per-engine stream (internal): created fresh inside `startEngine()`, finished inside
///   `stopEngine()`. A pump task bridges per-engine buffers into `mediumStream`.
///
/// Path B device-switch sequence: `stopEngine()` → sleep 300ms → `startEngine()`.
/// The pump drains before the new engine starts, preventing concurrent writers on `mediumStream`.
final class AudioPipeline {
    private(set) var isStarted: Bool = false
    // Set by stopEngine() so the next startEngine() recreates the AVAudioEngine instance.
    private var needsEngineRecreateOnNextStart = false

    // Session-lifetime stream: survives engine switches; only finished on stop().
    // nonisolated(unsafe): read by backends/LD from non-MainActor task contexts; the write in
    // start() happens-before the read via the SessionCoordinator wiring sequence.
    nonisolated(unsafe) private(set) var mediumStream: AsyncStream<CapturedAudioBuffer>
    nonisolated(unsafe) private var mediumContinuation: AsyncStream<CapturedAudioBuffer>.Continuation

    // Per-engine continuation: written by the Core Audio tap callback (any thread).
    nonisolated(unsafe) private var engineContinuation: AsyncStream<CapturedAudioBuffer>.Continuation?

    // Bridges per-engine buffers into mediumStream. One pump per engine lifetime.
    private var pumpTask: Task<Void, Never>?

    private let provider: any AudioEngineProvider

    init(provider: any AudioEngineProvider = SystemAudioEngineProvider()) {
        self.provider = provider
        // Placeholder; replaced by the first start().
        var cont: AsyncStream<CapturedAudioBuffer>.Continuation!
        self.mediumStream = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { cont = $0 }
        self.mediumContinuation = cont
    }

    deinit {
        mediumContinuation.finish()
    }

    // MARK: - Public API

    func start() throws {
        guard !isStarted else { return }

        // Fresh session-lifetime stream for this session.
        var cont: AsyncStream<CapturedAudioBuffer>.Continuation!
        self.mediumStream = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { cont = $0 }
        self.mediumContinuation = cont

        try startEngine()
        isStarted = true
    }

    func stop() {
        guard isStarted else { return }
        stopEngine()
        mediumContinuation.finish()
        isStarted = false
    }

    /// Recycles the AVAudioEngine on the current session's `mediumStream`.
    /// Consumers see a brief buffer gap but not stream termination (AC-SW7).
    func switchDevice() async throws {
        // Capture and detach the old pump before touching the engine.
        let oldPump = pumpTask
        pumpTask = nil
        engineContinuation?.finish()
        engineContinuation = nil
        provider.removeTap()
        provider.stop()
        needsEngineRecreateOnNextStart = true

        // Drain the old pump so two pumps never write to mediumContinuation concurrently.
        oldPump?.cancel()
        await oldPump?.value

        // HAL settle window (Path B — Spike #19 Hypothesis B).
        try await Task.sleep(for: .milliseconds(300))
        try startEngine()
    }

    // MARK: - Private

    private func startEngine() throws {
        if needsEngineRecreateOnNextStart {
            provider.recreate()
            needsEngineRecreateOnNextStart = false
        }

        // Per-engine stream: tap callback writes here; pump reads.
        var engCont: AsyncStream<CapturedAudioBuffer>.Continuation!
        let engineStream = AsyncStream<CapturedAudioBuffer>(bufferingPolicy: .bufferingNewest(64)) {
            engCont = $0
        }
        self.engineContinuation = engCont

        do {
            try provider.setVoiceProcessingEnabled(false)
        } catch {
            engCont.finish()
            self.engineContinuation = nil
            throw AudioPipelineError.vpioConfigurationFailed(underlying: error)
        }

        provider.installTap(
            bufferSize: 0,
            format: nil,
            block: makeTapBlock(continuation: engCont)
        )

        provider.prepare()

        do {
            try provider.start()
        } catch {
            provider.removeTap()
            engCont.finish()
            self.engineContinuation = nil
            throw AudioPipelineError.engineStartFailed(underlying: error)
        }

        // Pump bridges per-engine buffers into the session-lifetime mediumStream.
        let mc = mediumContinuation
        pumpTask = Task { [engineStream] in
            for await buffer in engineStream {
                mc.yield(buffer)
            }
        }

        logInputDeviceIdentity()
    }

    private func stopEngine() {
        engineContinuation?.finish()
        engineContinuation = nil
        pumpTask?.cancel()
        pumpTask = nil
        provider.removeTap()
        provider.stop()
        needsEngineRecreateOnNextStart = true
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
}
