@preconcurrency import AVFAudio
import FluidAudio
import Foundation

// MARK: - Model bootstrap

// Creates and loads a StreamingEouAsrManager for the specified chunk size.
// On first run, downloads the EOU model from HuggingFace (~100-200MB).
// Subsequent runs load from cache in ~/Library/Application Support/FluidAudio/Models/
public func loadEouManager(
    chunkSize: StreamingChunkSize = .ms160,
    reportProgress: @escaping @Sendable (String) -> Void = { _ in }
) async throws -> StreamingEouAsrManager {
    let manager = StreamingEouAsrManager(chunkSize: chunkSize)
    try await manager.loadModels(
        to: nil,
        configuration: nil,
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
    return manager
}

// MARK: - File processing

// Processes a single .caf audio file through StreamingEouAsrManager and returns
// all emission events annotated with timing metadata.
// Audio is fed at real-time pace (10ms per 160-frame buffer at 16kHz).
// Uses polling via getPartialTranscript() after each process() call — no callback
// threading complexity; sequential and race-free under Swift 6 strict concurrency.
public func processAudioFile(
    url: URL,
    manager: StreamingEouAsrManager
) async throws -> [TokenEvent] {
    // Reset manager state for this file (clears audio buffer, token IDs, loopback caches).
    await manager.reset()

    let sessionStart = Date()
    var events: [TokenEvent] = []
    var prevTranscript = ""

    // Helper: emit an event if the transcript changed since the last emission.
    func maybeEmit(text: String, isConfirmed: Bool) {
        guard text != prevTranscript || isConfirmed else { return }
        let emissionMs = Date().timeIntervalSince(sessionStart) * 1_000.0
        let prevMs = events.last?.emissionMs ?? 0.0
        let gap = events.isEmpty ? emissionMs : emissionMs - prevMs
        let event = TokenEvent(
            updateIndex: events.count,
            emissionMs: emissionMs,
            gapFromPreviousMs: gap,
            text: text,
            isConfirmed: isConfirmed,
            // -1.0 sentinel: RNNT streaming has no per-chunk confidence score.
            // isConfirmed=true at EOU/finish() is the utterance-level commit signal.
            confidence: isConfirmed ? 1.0 : -1.0
        )
        events.append(event)
        prevTranscript = text
        fputs(
            "[+\(Int(emissionMs))ms] "
            + "\"\(text.prefix(60))\" "
            + "confirmed=\(isConfirmed)\n",
            stderr
        )
    }

    // Open audio file and set up converter to 16 kHz mono PCM float32.
    let audioFile = try AVAudioFile(forReading: url)
    let sourceFormat = audioFile.processingFormat

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

    // 160 output samples = 10ms at 16 kHz.
    let outFrames: AVAudioFrameCount = 160
    let srcFrames = AVAudioFrameCount(
        ceil(Double(outFrames) * sourceFormat.sampleRate / targetSampleRate)
    )

    // Feed loop: read and process audio at real-time pace.
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

        // Real-time pace: 10ms sleep matches buffer audio duration.
        try await Task.sleep(nanoseconds: 10_000_000)

        // process() internally accumulates audio and runs inference when a full chunk
        // (2560 samples for 160ms) is buffered. It shifts by 1280 samples (80ms) per chunk.
        _ = try await manager.process(audioBuffer: outBuf)

        // Poll for new tokens. getPartialTranscript() returns the accumulated transcript
        // decoded from accumulatedTokenIds so far. Called after process() completes,
        // so no concurrency issue (sequential awaits on the same actor).
        let current = await manager.getPartialTranscript()
        if current != prevTranscript && !current.isEmpty {
            maybeEmit(text: current, isConfirmed: false)
        }
    }

    // Process any remaining buffered audio; returns final accumulated transcript.
    let finalTranscript = try await manager.finish()
    if !finalTranscript.isEmpty {
        // Always emit finish() result as isConfirmed=true (utterance-level commit signal).
        maybeEmit(text: finalTranscript, isConfirmed: true)
    }

    return events
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
