@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech
import os

// MARK: - AppleTranscriberBackend

/// Wraps `SpeechAnalyzer` + `SpeechTranscriber` for Apple-supported locales.
/// Uses two actor-isolated background tasks: one feeds converted audio buffers
/// into the analyzer, the other relays tokenized results to `tokenStream`.
actor AppleTranscriberBackend: TranscriberBackend {

    // MARK: Static config — inspectable in unit tests (AC5/AC7/AC8)

    nonisolated static let reportingOptions: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
    nonisolated static let attributeOptions: Set<SpeechTranscriber.ResultAttributeOption> = [.audioTimeRange]

    // nonisolated let escapes actor isolation — Logger is Sendable so this is safe.
    nonisolated private let logger = Logger.appleBackend

    // MARK: TranscriberBackend

    nonisolated let tokenStream: AsyncStream<TranscribedToken>

    // MARK: Private stored

    private let audioBufferProvider: any AudioBufferProvider
    private let localesProvider: any SupportedLocalesProvider
    private let assetStatusProvider: any AssetInventoryStatusProvider
    private let continuation: AsyncStream<TranscribedToken>.Continuation
    private var feedTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?

    // Non-Sendable Apple type — written once in start() before tasks access it.
    // nonisolated(unsafe) opts out of Swift 6 Sendability enforcement; actor
    // serialization keeps the write-then-read ordering safe.
    nonisolated(unsafe) private var _transcriber: SpeechTranscriber?

    // MARK: Init

    init(
        audioBufferProvider: any AudioBufferProvider,
        localesProvider: any SupportedLocalesProvider = SystemSupportedLocalesProvider(),
        assetStatusProvider: any AssetInventoryStatusProvider = SystemAssetInventoryStatusProvider()
    ) {
        self.audioBufferProvider = audioBufferProvider
        self.localesProvider = localesProvider
        self.assetStatusProvider = assetStatusProvider

        var cont: AsyncStream<TranscribedToken>.Continuation!
        self.tokenStream = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { cont = $0 }
        self.continuation = cont
    }

    // MARK: TranscriberBackend

    func start(locale: Locale) async throws {
        // Find the canonical Apple locale. Never use supportedLocale(equivalentTo:)
        // — it gives misleading results for unsupported locales (Session 006).
        let appleLocales = await localesProvider.supportedLocales()
        guard let matched = appleLocales.first(where: { localeMatches($0, locale) }) else {
            throw TranscriberBackendError.unsupportedLocale(locale)
        }

        let transcriber = SpeechTranscriber(
            locale: matched,
            transcriptionOptions: [],
            reportingOptions: Self.reportingOptions,
            attributeOptions: Self.attributeOptions
        )

        // Sessions must never trigger network IO. Refuse if model is not on disk.
        let installed = try await assetStatusProvider.isInstalled(transcriber: transcriber)
        guard installed else {
            throw TranscriberBackendError.modelUnavailable
        }

        self._transcriber = transcriber

        let (inputStream, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let bufferStream = audioBufferProvider.bufferStream()
        let cont = self.continuation

        // Result task: iterate transcriber.results, tokenize, relay to tokenStream
        resultTask = Task { [self] in
            guard let t = self._transcriber else { return }
            do {
                for try await result in t.results {
                    if Task.isCancelled { break }
                    for token in tokenize(from: result) {
                        cont.yield(token)
                    }
                }
            } catch is CancellationError {
                // intentional stop via task cancellation
            } catch {
                logger.error("AppleTranscriberBackend: result stream error: \(error)")
            }
            cont.finish()
        }

        // Feed task: set up SpeechAnalyzer on first buffer, convert + feed each buffer
        feedTask = Task { [self] in
            var analyzerStarted = false
            var converter: AVAudioConverter?
            var analyzerFormat: AVAudioFormat?

            for await capturedBuffer in bufferStream {
                if Task.isCancelled { break }

                if !analyzerStarted {
                    guard let t = self._transcriber else { break }
                    guard let sourceFormat = AVAudioFormat(
                        standardFormatWithSampleRate: capturedBuffer.sampleRate,
                        channels: AVAudioChannelCount(capturedBuffer.channelCount)
                    ) else { continue }

                    let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                        compatibleWith: [t], considering: sourceFormat
                    )
                    let af = targetFormat ?? sourceFormat
                    analyzerFormat = af

                    if let tf = targetFormat, tf != sourceFormat {
                        converter = AVAudioConverter(from: sourceFormat, to: tf)
                    }

                    let analyzer = SpeechAnalyzer(modules: [t])
                    do {
                        try await analyzer.prepareToAnalyze(in: af)
                        try await analyzer.start(inputSequence: inputStream)
                    } catch {
                        logger.error("AppleTranscriberBackend: analyzer start failed: \(error)")
                        break
                    }
                    logger.info(
                        "AppleTranscriberBackend: SpeechAnalyzer started (\(af.sampleRate)Hz \(af.channelCount)ch)"
                    )
                    analyzerStarted = true
                }

                guard let af = analyzerFormat else { continue }
                guard let pcm = toPCMBuffer(capturedBuffer) else { continue }

                let analyzerBuffer: AVAudioPCMBuffer
                if let conv = converter {
                    let ratio = af.sampleRate / pcm.format.sampleRate
                    let outCount = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 1
                    guard let converted = AVAudioPCMBuffer(pcmFormat: af, frameCapacity: outCount) else {
                        continue
                    }
                    var convError: NSError?
                    conv.convert(to: converted, error: &convError, withInputFrom: makeConverterBlock(source: pcm))
                    if let convError {
                        logger.warning("AppleTranscriberBackend: audio conversion error: \(convError)")
                        continue
                    }
                    analyzerBuffer = converted
                } else {
                    analyzerBuffer = pcm
                }

                inputContinuation.yield(AnalyzerInput(buffer: analyzerBuffer))
            }

            inputContinuation.finish()
        }
    }

    func stop() async {
        feedTask?.cancel()
        resultTask?.cancel()
        feedTask = nil
        resultTask = nil
        _transcriber = nil
        continuation.finish()
    }
}

// MARK: - Tokenizer

/// Extracts `TranscribedToken` values from one `SpeechTranscriber.Result`.
/// Known v1 limitation: multiple words sharing one `AttributedString` run receive
/// identical startTime/endTime. Per-word interpolation deferred to v1.x.
nonisolated func tokenize(from result: SpeechTranscriber.Result) -> [TranscribedToken] {
    let isFinal = result.isFinal
    let text = result.text
    var tokens: [TranscribedToken] = []

    for run in text.runs {
        let key = AttributeScopes.SpeechAttributes.TimeRangeAttribute.self
        guard let timeRange = run[key] else { continue }

        let raw = String(text[run.range].characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !raw.isEmpty else { continue }

        let start = CMTimeGetSeconds(timeRange.start)
        let end = CMTimeGetSeconds(timeRange.end)

        for part in raw.split(separator: " ") {
            tokens.append(TranscribedToken(
                word: String(part),
                startTime: start,
                endTime: end,
                isFinal: isFinal
            ))
        }
    }

    return tokens
}

// MARK: - Private helpers

private nonisolated func toPCMBuffer(_ buffer: CapturedAudioBuffer) -> AVAudioPCMBuffer? {
    guard let fmt = AVAudioFormat(
        standardFormatWithSampleRate: buffer.sampleRate,
        channels: AVAudioChannelCount(buffer.channelCount)
    ),
    let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: buffer.frameLength) else {
        return nil
    }
    pcm.frameLength = buffer.frameLength
    if let channelData = pcm.floatChannelData {
        for (ch, samples) in buffer.samples.enumerated() {
            let dst = channelData[ch]
            samples.withUnsafeBufferPointer { buf in
                guard let src = buf.baseAddress else { return }
                dst.initialize(from: src, count: buf.count)
            }
        }
    }
    return pcm
}

private nonisolated func makeConverterBlock(source: AVAudioPCMBuffer) -> AVAudioConverterInputBlock {
    // Class wrapper avoids capturing a mutable var in a @Sendable closure (Swift 6).
    // AVAudioConverter calls this block on one thread at a time, so no lock needed.
    final class ConsumedFlag: @unchecked Sendable { var value = false }
    let flag = ConsumedFlag()
    return { _, outStatus in
        if !flag.value {
            flag.value = true
            outStatus.pointee = .haveData
            return source
        }
        outStatus.pointee = .noDataNow
        return nil
    }
}
