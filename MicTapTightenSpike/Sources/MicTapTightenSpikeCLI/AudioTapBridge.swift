import AVFoundation
import os

// MARK: - Sendable buffer value type

/// A Sendable snapshot of an `AVAudioPCMBuffer` captured inside the audio tap closure.
///
/// `AVAudioPCMBuffer` is non-Sendable and may be reused by Core Audio after the tap
/// callback returns. All data must be copied out within the callback. This struct
/// carries the copied data safely across the CoreAudio-thread → actor boundary.
nonisolated struct CapturedAudioBuffer: Sendable {
    let frameLength: AVAudioFrameCount
    let sampleRate: Double
    let channelCount: UInt32
    let sampleTime: Int64
    let hostTime: UInt64
    /// Non-interleaved PCM samples copied from `AVAudioPCMBuffer.floatChannelData`.
    /// Outer array = channels, inner array = frames. Size = channelCount × frameLength.
    let samples: [[Float]]
}

// MARK: - Tap block factory (nonisolated — the load-bearing isolation boundary)

/// Creates the audio tap callback closure.
///
/// This function is explicitly `nonisolated` to ensure the returned closure does NOT
/// inherit `@MainActor` isolation. Under the production project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, omitting `nonisolated` would make this
/// function — and therefore the returned closure — MainActor-isolated. The closure would
/// then crash at runtime with `_dispatch_assert_queue_fail` when CoreAudio invokes it on
/// its `RealtimeMessenger.mServiceQueue`.
///
/// In SPM packages without default-MainActor isolation, the `nonisolated` keyword is
/// redundant but harmless. In the production Xcode project, it is load-bearing.
///
/// **What M3.1 copies verbatim:** this function signature, the `nonisolated` keyword,
/// the `@Sendable` return type, and the closure body pattern (capture only Sendable
/// values, copy all data out of `AVAudioPCMBuffer` before yielding).
///
/// - Parameter continuation: The `AsyncStream.Continuation` that delivers buffers to the
///   consuming actor. `Continuation` conforms to `Sendable`, so capturing it in a
///   `@Sendable` closure is legal.
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

private let logger = Logger(subsystem: "com.talkcoach.spike", category: "audioTapBridge")

// MARK: - AudioTapBridge lifecycle manager

/// Manages the AVAudioEngine input tap lifecycle and bridges audio buffers to an
/// `AsyncStream` consumed by an actor.
///
/// **Production note on isolation:** In the production Xcode project,
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes this class implicitly `@MainActor`.
/// SPM packages do not have this build setting, so the spike omits the annotation.
/// The critical isolation boundary — `nonisolated func makeTapBlock` above — is validated
/// regardless. M3.1's `AudioPipeline` will be implicitly `@MainActor` via the build
/// setting; its lifecycle methods (`start`, `recover`, `stop`) run on MainActor; the tap
/// closure is produced by the `nonisolated` factory function, never by a method on the
/// class. See REPORT.md "How M3.1 copies this" for the production form.
final class AudioTapBridge: @unchecked Sendable {
    private let continuation: AsyncStream<CapturedAudioBuffer>.Continuation

    /// The consumer-side stream. The consuming actor iterates this with `for await`.
    let bufferStream: AsyncStream<CapturedAudioBuffer>

    /// - Parameter bufferPolicy: The `AsyncStream` buffering policy.
    ///   Default `.bufferingNewest(64)`: when the consumer falls behind, the oldest
    ///   buffered elements are dropped and the 64 newest are retained. This is correct
    ///   for real-time audio — stale audio is worse than skipped audio.
    ///   See Apple docs: `AsyncStream.Continuation.BufferingPolicy.bufferingNewest(_:)`.
    init(
        bufferPolicy: AsyncStream<CapturedAudioBuffer>.Continuation.BufferingPolicy
            = .bufferingNewest(64)
    ) {
        var cont: AsyncStream<CapturedAudioBuffer>.Continuation!
        self.bufferStream = AsyncStream(bufferingPolicy: bufferPolicy) { cont = $0 }
        self.continuation = cont
    }

    /// Installs the audio tap on the given input node.
    ///
    /// The tap block is created by the `nonisolated` `makeTapBlock` factory, ensuring
    /// the closure does not inherit this class's `@MainActor` isolation.
    func install(on inputNode: AVAudioInputNode) {
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: nil,
            block: makeTapBlock(continuation: continuation)
        )
        logger.info("Tap installed (format: nil, bufferSize: 4096)")
    }

    /// Runs the configuration-change recovery cycle.
    ///
    /// Called from the `AVAudioEngineConfigurationChange` observer (which runs on
    /// `queue: .main`, i.e. MainActor). The recovery sequence:
    /// 1. Remove the old tap (engine is already stopped per Apple docs).
    /// 2. Check and re-disable VPIO if the config change reset it.
    /// 3. Reinstall the tap with `format: nil` — picks up the new hardware format.
    ///    Uses the SAME continuation, so the consumer's `for await` is uninterrupted.
    /// 4. Prepare and restart the engine.
    func recover(engine: AVAudioEngine, inputNode: AVAudioInputNode) {
        inputNode.removeTap(onBus: 0)
        logger.info("Tap removed for recovery")

        if inputNode.isVoiceProcessingEnabled {
            logger.info("VPIO was reset to true by config change — re-disabling")
            do {
                try inputNode.setVoiceProcessingEnabled(false)
            } catch {
                logger.error("Failed to re-disable VPIO: \(error)")
            }
        }

        let newFormat = inputNode.inputFormat(forBus: 0)
        logger.info(
            "Post-change format: \(newFormat.sampleRate) Hz, \(newFormat.channelCount) ch"
        )

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: nil,
            block: makeTapBlock(continuation: continuation)
        )
        logger.info("Tap reinstalled with format: nil")

        engine.prepare()
        do {
            try engine.start()
            logger.info("Engine restarted after config change")
        } catch {
            logger.error("Engine restart failed: \(error)")
        }
    }

    /// Stops the tap and finishes the buffer stream.
    func stop(inputNode: AVAudioInputNode) {
        inputNode.removeTap(onBus: 0)
        continuation.finish()
        logger.info("Tap removed, stream finished")
    }

    deinit {
        continuation.finish()
    }
}
