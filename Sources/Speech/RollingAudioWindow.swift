import AVFoundation
import OSLog

/// Maintains a rolling 16 kHz mono f32 ring buffer and fires 3-second hop snapshots.
///
/// Architecture AA constants:
///   - Window: 10s = 160,000 samples at 16 kHz
///   - Buffer cap: 12s = 192,000 samples (headroom above window floor)
///   - Hop: 3s
actor RollingAudioWindow {
    static let targetSampleRate: Double = 16_000
    static let windowSamples: Int = 160_000    // 10s @ 16 kHz
    static let bufferCapSamples: Int = 192_000  // 12s @ 16 kHz
    static let hopSeconds: Double = 3.0

    private var buffer: [Float] = []
    private var converter: AVAudioConverter?
    private var hopTask: Task<Void, Never>?

    private let hopContinuation: AsyncStream<[Float]>.Continuation
    let hopStream: AsyncStream<[Float]>

    init() {
        var cont: AsyncStream<[Float]>.Continuation!
        hopStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        hopContinuation = cont
    }

    /// Configure the resampling converter from the input buffer's format.
    /// Must be called before `append(_:)`. Safe to call multiple times if format is stable.
    func configure(sampleRate: Double, channelCount: UInt32) throws {
        guard let inputFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount)
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RollingAudioWindowError.formatCreationFailed
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RollingAudioWindowError.converterCreationFailed
        }
        self.converter = conv
    }

    /// Append a captured buffer. Resamples to 16 kHz mono f32 and appends to ring buffer.
    func append(_ captured: CapturedAudioBuffer) throws {
        guard let conv = converter else { return }

        let frameCount = Int(captured.frameLength)
        guard frameCount > 0, let inputFormat = AVAudioFormat(
            standardFormatWithSampleRate: captured.sampleRate,
            channels: AVAudioChannelCount(captured.channelCount)
        ), let inputPCM = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }

        inputPCM.frameLength = AVAudioFrameCount(frameCount)
        if let floatData = inputPCM.floatChannelData {
            let chCount = min(Int(captured.channelCount), captured.samples.count)
            for ch in 0..<chCount {
                captured.samples[ch].withUnsafeBufferPointer { src in
                    floatData[ch].update(from: src.baseAddress!, count: src.count)
                }
            }
        }

        let ratio = Self.targetSampleRate / captured.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(ceil(Double(frameCount) * ratio)) + 1
        guard let outputPCM = AVAudioPCMBuffer(pcmFormat: conv.outputFormat, frameCapacity: outputFrameCapacity) else { return }

        var inputConsumed = false
        let status = conv.convert(to: outputPCM, error: nil) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputPCM
        }

        guard status != .error, let channelData = outputPCM.floatChannelData else { return }
        let outFrames = Int(outputPCM.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: outFrames))

        buffer.append(contentsOf: samples)
        if buffer.count > Self.bufferCapSamples {
            buffer.removeFirst(buffer.count - Self.bufferCapSamples)
        }
    }

    /// Start the hop timer. Fires every `hopSeconds`, yielding a snapshot of the rolling window.
    func startHopTimer() {
        hopTask = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.hopSeconds))
                if Task.isCancelled { break }
                fireHop()
            }
        }
    }

    func stopHopTimer() {
        hopTask?.cancel()
        hopTask = nil
        hopContinuation.finish()
    }

    private func fireHop() {
        let snapshot = Array(buffer.suffix(Self.windowSamples))
        guard !snapshot.isEmpty else { return }
        hopContinuation.yield(snapshot)
    }
}

enum RollingAudioWindowError: Error {
    case formatCreationFailed
    case converterCreationFailed
}
