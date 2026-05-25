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

    private var sessionWallStart: TimeInterval = 0

    init() {
        // swiftlint:disable identifier_name
        var tc: AsyncStream<TranscribedToken>.Continuation!
        tokenStream = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { tc = $0 }
        tokenCont = tc

        var ec: AsyncStream<Void>.Continuation!
        engineReadyStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { ec = $0 }
        engineReadyCont = ec
        // swiftlint:enable identifier_name
    }

    func start(locale: Locale, audioProvider: (any AudioBufferProvider)?) async throws {
        sessionWallStart = Date().timeIntervalSinceReferenceDate
        engineReadyFired = false

        let modelDir: URL
        do {
            modelDir = try ParakeetModelLoader.modelDirectoryURL()
        } catch {
            Logger.speech.error("ParakeetBackend: model directory not found — \(error)")
            throw TranscriberBackendError.modelUnavailable
        }
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
        await bufferTask?.value
        bufferTask = nil
        inferTask?.cancel()
        await inferTask?.value
        inferTask = nil
        await rollingWindow.stopHopTimer()
        if let eng = engine {
            pk_engine_destroy(eng)
            engine = nil
        }
    }

    /// Session-absolute start of the window being inferred.
    ///
    /// Parakeet returns token timestamps relative to the window's own start (0…~windowDuration).
    /// Adding this offset converts them to session-absolute time, consistent with the
    /// session-clock elapsed value used to query isCurrentlySpeaking(asOf:).
    #if DEBUG
    func yieldTestToken(_ token: TranscribedToken) {
        tokenCont.yield(token)
    }

    func yieldEngineReadyForTesting() {
        engineReadyCont.yield(())
    }
    #endif

    nonisolated static func windowAbsoluteStart(elapsed: TimeInterval, sampleCount: Int) -> TimeInterval {
        elapsed - TimeInterval(sampleCount) / 16_000
    }

    private func infer(samples: [Float]) async {
        guard let eng = engine else { return }

        // Compute elapsed and window offset before inference so both use the same clock reference.
        let elapsed = Date().timeIntervalSinceReferenceDate - sessionWallStart
        let windowStart = Self.windowAbsoluteStart(elapsed: elapsed, sampleCount: samples.count)

        let result: UnsafeMutablePointer<PkResult>? = samples.withUnsafeBufferPointer { ptr in
            pk_transcribe(eng, ptr.baseAddress!, ptr.count)
        }
        guard let result else { return }
        defer { pk_free_result(result) }

        let wordCount = Int(result.pointee.word_count)
        let text = result.pointee.text.map { String(cString: $0) } ?? ""

        if wordCount > 0, let tokensPtr = result.pointee.tokens {
            // tok.start/end are window-relative (0…~windowDuration). Offset to session-absolute.
            let firstTokenAbsStart = windowStart + TimeInterval(tokensPtr[0].start)
            let lastTokenAbsEnd = windowStart + TimeInterval(tokensPtr[wordCount - 1].end)

            if !text.isEmpty {
                tokenCont.yield(TranscribedToken(
                    token: text,
                    startTime: firstTokenAbsStart,
                    endTime: lastTokenAbsEnd,
                    isFinal: true
                ))
            }
        }

        if !engineReadyFired {
            engineReadyCont.yield(())
            engineReadyFired = true
        }

        Logger.speech.info("ParakeetBackend: hop — \(wordCount) words")
    }
}
