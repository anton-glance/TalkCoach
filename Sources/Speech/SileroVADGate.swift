import AVFoundation
import OSLog

// MARK: - VAD transition events

enum VADTransitionEvent: Sendable {
    case speechStarted(sessionTime: TimeInterval)
    case speechStopped(sessionTime: TimeInterval)
}

// MARK: - VADFrameProcessor protocol

/// Processes a single 512-sample frame and returns a speech probability in [0, 1].
/// Stateful (GRU hidden state lives inside); `reset()` clears state between sessions.
nonisolated protocol VADFrameProcessor: Sendable {
    func processFrame(_ samples: [Float]) -> Float
    func reset()
}

// MARK: - SileroVADGate

/// Consumes an `AsyncStream<CapturedAudioBuffer>`, resamples to 16 kHz mono,
/// chops to 512-sample (32ms) frames, runs each frame through `VADFrameProcessor`,
/// and emits raw `VADTransitionEvent` values on `transitionStream`.
///
/// Raw-transition semantics: the gate emits the instant state changes
/// (speechStarted / speechStopped). Product-level grace tolerances live downstream
/// in M4 consumers (e.g. WPM 2s, Monologue 2.5s). The only smoothing here is a
/// short jitter debounce to suppress sub-debounce chatter.
///
/// Session timestamps are audio-time-based:
///   elapsed = processedFrames × frameSamples / 16_000
/// This ensures deterministic, reproducible timestamps in tests regardless of
/// wall-clock execution speed.
actor SileroVADGate {
    // MARK: Constants

    /// Samples per Silero v5 frame at 16 kHz.
    static let frameSamples = 512
    /// Consecutive silence frames required before emitting speechStopped (5 × 32ms = 160ms).
    static let offlineDebounceFrames = 5
    /// Consecutive voice frames required before emitting speechStarted (1 × 32ms = 32ms).
    static let onlineDebounceFrames = 1
    /// Probability threshold for speech / silence classification.
    static let vadThreshold: Float = 0.5

    // MARK: State

    private let frameProcessor: any VADFrameProcessor
    private var bufferTask: Task<Void, Never>?
    private var processedFrames: Int = 0
    private var isSpeaking: Bool = false
    private var consecutiveSilentFrames: Int = 0
    private var consecutiveVoiceFrames: Int = 0

    // MARK: Output stream

    private let transitionCont: AsyncStream<VADTransitionEvent>.Continuation
    nonisolated let transitionStream: AsyncStream<VADTransitionEvent>

    // MARK: Init

    init(frameProcessor: any VADFrameProcessor) {
        self.frameProcessor = frameProcessor
        var cont: AsyncStream<VADTransitionEvent>.Continuation!
        transitionStream = AsyncStream(bufferingPolicy: .bufferingNewest(32)) { cont = $0 }
        transitionCont = cont
    }

    // MARK: Lifecycle

    /// Begin consuming `stream`, resampling and chunking into VAD frames.
    func start(stream: AsyncStream<CapturedAudioBuffer>) async {
        frameProcessor.reset()
        processedFrames = 0
        isSpeaking = false
        consecutiveSilentFrames = 0
        consecutiveVoiceFrames = 0

        bufferTask = Task { [weak self] in
            await self?.feed(stream: stream)
        }
    }

    func stop() async {
        bufferTask?.cancel()
        await bufferTask?.value
        bufferTask = nil
        transitionCont.finish()
        Logger.speech.info("SileroVADGate: stopped")
    }

    // MARK: Internal test helper

    // Drives the debounce state machine directly with a known probability value,
    // bypassing the audio stream → resample → frame pipeline. For unit tests only.
    // swiftlint:disable:next identifier_name
    func _testProcessFrame(_ prob: Float) {
        processedFrames += 1
        let elapsed = TimeInterval(processedFrames) * Double(Self.frameSamples) / 16_000.0
        _updateDebounce(prob: prob, elapsed: elapsed)
    }

    // MARK: Private

    private func feed(stream: AsyncStream<CapturedAudioBuffer>) async {
        var resampleBuffer: [Float] = []

        for await buffer in stream {
            if Task.isCancelled { break }

            let mono = downsampleToMono(buffer)
            let resampled = resample(mono, fromRate: buffer.sampleRate, toRate: 16_000)
            resampleBuffer.append(contentsOf: resampled)

            while resampleBuffer.count >= Self.frameSamples {
                let frame = Array(resampleBuffer.prefix(Self.frameSamples))
                resampleBuffer.removeFirst(Self.frameSamples)

                let prob = frameProcessor.processFrame(frame)
                processedFrames += 1
                let elapsed = TimeInterval(processedFrames) * Double(Self.frameSamples) / 16_000.0
                _updateDebounce(prob: prob, elapsed: elapsed)
            }
        }
    }

    private func _updateDebounce(prob: Float, elapsed: TimeInterval) {
        if prob >= Self.vadThreshold {
            consecutiveSilentFrames = 0
            consecutiveVoiceFrames += 1
            if !isSpeaking, consecutiveVoiceFrames >= Self.onlineDebounceFrames {
                isSpeaking = true
                consecutiveVoiceFrames = 0
                transitionCont.yield(.speechStarted(sessionTime: elapsed))
                Logger.speech.info("SileroVADGate: speechStarted at \(elapsed, format: .fixed(precision: 3))s")
            }
        } else {
            consecutiveVoiceFrames = 0
            consecutiveSilentFrames += 1
            if isSpeaking, consecutiveSilentFrames >= Self.offlineDebounceFrames {
                isSpeaking = false
                consecutiveSilentFrames = 0
                transitionCont.yield(.speechStopped(sessionTime: elapsed))
                Logger.speech.info("SileroVADGate: speechStopped at \(elapsed, format: .fixed(precision: 3))s")
            }
        }
    }

    // MARK: Audio helpers

    private func downsampleToMono(_ buffer: CapturedAudioBuffer) -> [Float] {
        guard !buffer.samples.isEmpty else { return [] }
        let count = Int(buffer.frameLength)
        if buffer.samples.count == 1 { return buffer.samples[0] }
        // Mix channels to mono
        var mono = [Float](repeating: 0.0, count: count)
        let scale = 1.0 / Float(buffer.samples.count)
        for channel in buffer.samples {
            for idx in 0..<min(count, channel.count) {
                mono[idx] += channel[idx] * scale
            }
        }
        return mono
    }

    /// Nearest-neighbour integer-ratio downsampling to 16 kHz.
    /// For typical mic rates (44100, 48000) this is a coarse approximation;
    /// rubato-quality resampling is in the Rust pipeline for production paths.
    /// This Swift path handles the coordinator-direct wiring if needed.
    private func resample(_ samples: [Float], fromRate: Double, toRate: Double) -> [Float] {
        guard fromRate != toRate, !samples.isEmpty else { return samples }
        let ratio = fromRate / toRate
        let outputCount = Int(Double(samples.count) / ratio)
        var output = [Float]()
        output.reserveCapacity(outputCount)
        for idx in 0..<outputCount {
            let srcIdx = Int(Double(idx) * ratio)
            output.append(samples[min(srcIdx, samples.count - 1)])
        }
        return output
    }
}
