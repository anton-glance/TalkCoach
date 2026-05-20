@preconcurrency import AVFAudio
import FluidAudio
import Foundation

// MARK: - Model bootstrap

// Loads AsrModels once. Intended as a process-lifetime singleton — re-calling
// downloadAndLoad is safe (FluidAudio caches the compiled model on disk).
// On macOS, no AVAudioSession setup is required (that is iOS-specific in TiltTalk's
// ParakeetSpeechService; FluidAudio itself does not configure the audio session).
public func loadParakeetModels(
    reportProgress: @escaping @Sendable (String) -> Void = { _ in }
) async throws -> AsrModels {
    return try await AsrModels.downloadAndLoad(
        progressHandler: { progress in
            switch progress.phase {
            case .listing:
                reportProgress("listing")
            case let .downloading(completedFiles, totalFiles):
                reportProgress("downloading \(completedFiles)/\(totalFiles) files")
            case let .compiling(modelName):
                reportProgress("compiling \(modelName)")
            }
        }
    )
}

// MARK: - File processing

// Processes a single .caf audio file through SlidingWindowAsrManager and returns
// all update events annotated with timing metadata.
// Audio is fed at real-time pace (10ms per 160-frame buffer at 16kHz) so that
// emission timestamps reflect realistic pipeline latency.
public func processAudioFile(
    url: URL,
    models: AsrModels
) async throws -> [TokenEvent] {
    // Zero-context config: both cached model variants are compiled with a fixed
    // input shape of [1, 240000] (15s @ 16kHz). FluidAudio 0.14.7's default config
    // feeds left+chunk+right = 432000 samples, exceeding the model shape.
    // Zero context produces windows of exactly ≤ 240000; padAudioIfNeeded handles
    // shorter tail windows (< 240000) by zero-padding.
    let config = SlidingWindowAsrConfig(
        chunkSeconds: 15.0,
        hypothesisChunkSeconds: 2.0,
        leftContextSeconds: 0.0,
        rightContextSeconds: 0.0,
        minContextForConfirmation: 10.0,
        confirmationThreshold: 0.85
    )
    let manager = SlidingWindowAsrManager(config: config)
    try await manager.loadModels(models)

    // Subscribe BEFORE startStreaming to avoid the TiltTalk documented race:
    // updates emitted between startStreaming and subscription are lost because
    // the continuation is nil at that point.
    let updateStream = await manager.transcriptionUpdates

    // startStreaming is required — it launches the internal recognition task that
    // reads from the manager's inputSequence. Without it, streamAudio calls are
    // buffered but never processed. AudioSource.microphone is just a label on macOS;
    // actual audio comes from our streamAudio calls, not from a mic capture session.
    try await manager.startStreaming(source: .microphone)

    let sessionStart = Date()

    // Actor for safe cross-task result accumulation (Swift 6 strict concurrency).
    actor ResultBag {
        var events: [TokenEvent] = []
        func append(_ e: TokenEvent) { events.append(e) }
        func all() -> [TokenEvent] { events }
    }
    let bag = ResultBag()

    try await withThrowingTaskGroup(of: Void.self) { group in
        // Feed task: reads audio file in 10ms chunks at real-time pace.
        group.addTask {
            let audioFile = try AVAudioFile(forReading: url)
            let sourceFormat = audioFile.processingFormat

            // Parakeet expects 16 kHz mono PCM float32. Convert if needed.
            let targetSampleRate: Double = 16_000
            let needsConversion = sourceFormat.sampleRate != targetSampleRate
                || sourceFormat.channelCount != 1
            var converter: AVAudioConverter?
            let feedFormat: AVAudioFormat

            if needsConversion {
                guard let mono16k = AVAudioFormat(
                    standardFormatWithSampleRate: targetSampleRate,
                    channels: 1
                ) else {
                    throw AudioFileError.cannotCreateFormat
                }
                guard let conv = AVAudioConverter(from: sourceFormat, to: mono16k) else {
                    throw AudioFileError.cannotCreateConverter
                }
                converter = conv
                feedFormat = mono16k
            } else {
                feedFormat = sourceFormat
            }

            // Source frames needed per 10ms output buffer at the source sample rate.
            let outFrames: AVAudioFrameCount = 160
            let srcFrames = AVAudioFrameCount(
                ceil(Double(outFrames) * sourceFormat.sampleRate / targetSampleRate)
            )

            while !Task.isCancelled {
                let srcBuf = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    frameCapacity: needsConversion ? srcFrames : outFrames
                )!
                do {
                    try audioFile.read(into: srcBuf)
                } catch {
                    break  // EOF
                }
                guard srcBuf.frameLength > 0 else { break }

                let outBuf: AVAudioPCMBuffer
                if let conv = converter {
                    let converted = AVAudioPCMBuffer(
                        pcmFormat: feedFormat,
                        frameCapacity: outFrames + 1
                    )!
                    var convError: NSError?
                    let flag = ConversionConsumedFlag()
                    conv.convert(to: converted, error: &convError) { _, status in
                        if !flag.consumed {
                            flag.consumed = true
                            status.pointee = .haveData
                            return srcBuf
                        }
                        status.pointee = .noDataNow
                        return nil
                    }
                    if convError != nil { break }
                    outBuf = converted
                } else {
                    outBuf = srcBuf
                }

                // Real-time pace: 10ms sleep matches the buffer's audio duration.
                try await Task.sleep(nanoseconds: 10_000_000)
                // SlidingWindowAsrManager.streamAudio is synchronous on the actor;
                // the await here is for the actor isolation hop only.
                await manager.streamAudio(outBuf)
            }

            _ = try? await manager.finish()
        }

        // Collect task: iterates updateStream until cancelled.
        // Note: SlidingWindowAsrManager.finish() does NOT close the updateStream
        // continuation — only cancel() does. We must cancel this task after the
        // feed task completes, otherwise this loop waits forever.
        group.addTask {
            var prevMs: Double = 0.0
            var idx = 0
            for await update in updateStream {
                if Task.isCancelled { break }
                let emissionMs = Date().timeIntervalSince(sessionStart) * 1_000.0
                let gap = idx == 0 ? emissionMs : emissionMs - prevMs
                let event = TokenEvent(
                    updateIndex: idx,
                    emissionMs: emissionMs,
                    gapFromPreviousMs: gap,
                    text: update.text,
                    isConfirmed: update.isConfirmed,
                    confidence: update.confidence
                )
                await bag.append(event)
                fputs(
                    "[+\(Int(emissionMs))ms] "
                    + "\"\(update.text.prefix(60))\" "
                    + "confirmed=\(update.isConfirmed) "
                    + "conf=\(String(format: "%.2f", update.confidence))\n",
                    stderr
                )
                prevMs = emissionMs
                idx += 1
            }
        }

        // Wait for the first task to finish (feed task, which calls manager.finish()).
        // Then cancel the collect task — updateStream never closes on its own after finish().
        _ = try await group.next()
        group.cancelAll()
        try await group.waitForAll()
    }

    return await bag.all()
}

// MARK: - Errors

public enum AudioFileError: Error {
    case cannotCreateFormat
    case cannotCreateConverter
}

// MARK: - AVAudioConverter helper

// Wraps the "consumed" flag for the converter input block so it is
// @Sendable-safe under Swift 6 strict concurrency.
final class ConversionConsumedFlag: @unchecked Sendable {
    var consumed = false
}
