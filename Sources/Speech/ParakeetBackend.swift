import AVFoundation
import CParakeetBridge
import OSLog

/// Parakeet TDT v3 int8 transcription backend (Architecture AA).
///
/// Owns the Rust PkEngine pointer. Runs a 10s rolling window with 3s hops.
/// Warm-loads the model on `start()` and fires `engineReadyStream` after the
/// first successful hop.
actor ParakeetBackend: TranscriberBackend {
    // PkEngine * — opaque incomplete struct from C ABI; Swift imports as OpaquePointer.
    nonisolated(unsafe) private var engine: OpaquePointer?

    private let rollingWindow = RollingAudioWindow()
    private var inferTask: Task<Void, Never>?
    private var bufferTask: Task<Void, Never>?
    private var engineReadyFired = false

    private let tokenCont: AsyncStream<TranscribedToken>.Continuation
    nonisolated let tokenStream: AsyncStream<TranscribedToken>

    private let engineReadyCont: AsyncStream<Void>.Continuation
    nonisolated let engineReadyStream: AsyncStream<Void>

    private let speakingCont: AsyncStream<Bool>.Continuation
    nonisolated let speakingActivityStream: AsyncStream<Bool>

    private var sessionWallStart: TimeInterval = 0
    private var tracker = SpeakingActivityTracker()

    init() {
        var tc: AsyncStream<TranscribedToken>.Continuation!
        tokenStream = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { tc = $0 }
        tokenCont = tc

        var ec: AsyncStream<Void>.Continuation!
        engineReadyStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { ec = $0 }
        engineReadyCont = ec

        var sc: AsyncStream<Bool>.Continuation!
        speakingActivityStream = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { sc = $0 }
        speakingCont = sc
    }

    func start(locale: Locale, audioProvider: (any AudioBufferProvider)?) async throws {
        sessionWallStart = Date().timeIntervalSinceReferenceDate
        tracker = SpeakingActivityTracker()
        engineReadyFired = false

        let modelDir = try ParakeetModelLoader.modelDirectoryURL()
        let eng: OpaquePointer? = modelDir.path.withCString { pk_engine_create($0) }
        guard let eng else {
            Logger.speech.error("ParakeetBackend: pk_engine_create returned null — model not found at \(modelDir.path)")
            throw TranscriberBackendError.modelUnavailable
        }
        engine = eng
        Logger.speech.info("ParakeetBackend: engine loaded from \(modelDir.path)")

        if let provider = audioProvider {
            bufferTask = Task { [self] in
                var configured = false
                for await captured in provider.bufferStream() {
                    if Task.isCancelled { break }
                    if !configured {
                        try? await rollingWindow.configure(
                            sampleRate: captured.sampleRate,
                            channelCount: captured.channelCount
                        )
                        await rollingWindow.startHopTimer()
                        configured = true
                    }
                    try? await rollingWindow.append(captured)
                }
            }
        }

        inferTask = Task { [self] in
            for await samples in await rollingWindow.hopStream {
                if Task.isCancelled { break }
                await infer(samples: samples)
            }
        }
    }

    func stop() async {
        bufferTask?.cancel()
        bufferTask = nil
        inferTask?.cancel()
        inferTask = nil
        await rollingWindow.stopHopTimer()
        tokenCont.finish()
        engineReadyCont.finish()
        speakingCont.finish()
        if let eng = engine {
            pk_engine_destroy(eng)
            engine = nil
        }
    }

    private func infer(samples: [Float]) async {
        guard let eng = engine else { return }

        let result: UnsafeMutablePointer<PkResult>? = samples.withUnsafeBufferPointer { ptr in
            pk_transcribe(eng, ptr.baseAddress!, ptr.count)
        }
        guard let result else { return }
        defer { pk_free_result(result) }

        let wordCount = Int(result.pointee.word_count)
        let text = result.pointee.text.map { String(cString: $0) } ?? ""

        if wordCount > 0, let tokensPtr = result.pointee.tokens {
            let windowStart = TimeInterval(tokensPtr[0].start)
            let windowEnd = TimeInterval(tokensPtr[wordCount - 1].end)

            for i in 0..<wordCount {
                let tok = tokensPtr[i]
                tracker.addToken(TimestampedWord(
                    word: "",
                    startTime: TimeInterval(tok.start),
                    endTime: TimeInterval(tok.end)
                ))
            }

            if !text.isEmpty {
                tokenCont.yield(TranscribedToken(
                    token: text,
                    startTime: windowStart,
                    endTime: windowEnd,
                    isFinal: true
                ))
            }
        }

        let elapsed = Date().timeIntervalSinceReferenceDate - sessionWallStart
        let isSpeaking = tracker.isCurrentlySpeaking(asOf: elapsed)
        speakingCont.yield(isSpeaking)

        if !engineReadyFired {
            engineReadyCont.yield(())
            engineReadyFired = true
        }

        Logger.speech.info("ParakeetBackend: hop — \(wordCount) words, speaking=\(isSpeaking)")
    }
}
