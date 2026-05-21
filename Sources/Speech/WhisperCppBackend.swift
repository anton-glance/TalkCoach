import CWhisper
import Foundation
import os

// Raw token from the CWhisper bridge: text + centisecond timestamps + token probability.
struct RawWhisperToken {
    let text: String
    let t0Cs: Int64
    let t1Cs: Int64
    let prob: Float
}

// MARK: - WhisperCppBackend

/// Transcriber backend backed by whisper.cpp + Silero VAD (Architecture Z).
/// Lifecycle: one instance per app lifetime (engine-always-warm).
/// Whisper/VAD contexts are created on first start() and reused across sessions.
/// start()/stop() control per-session inference; contexts survive between sessions.
/// tokenStream and engineReadyStream are recreated per session (single-consumer contract).
actor WhisperCppBackend: TranscriberBackend {

    // Static properties are not actor-isolated — accessible from any context.
    private static let logger = Logger(subsystem: "com.talkcoach.app", category: "speech")

    // Minimum average token probability for a merged word to be emitted downstream.
    static let confidenceThreshold: Float = 0.4

    // Number of CPU threads used for both whisper and Silero inference.
    private static let inferenceThreads: Int32 = 4

    // 1-second inference window at 16 kHz.
    private static let kLengthSamples: Int = 16_000

    // Silero VAD probability threshold (0.5 = default from Spike #17.3 tuning).
    nonisolated(unsafe) static var vadThreshold: Float = 0.5

    // Counts GPU init failures within the current context creation attempt.
    // Reset before each attempt so transient Metal issues don't permanently lock to CPU.
    private(set) var metalFailureCount: Int = 0

    // Recreated per session (single-consumer contract, mirrors AudioPipeline pattern).
    nonisolated(unsafe) private(set) var tokenStream: AsyncStream<TranscribedToken>
    nonisolated(unsafe) private(set) var engineReadyStream: AsyncStream<Void>
    nonisolated let vadActivityStream: AsyncStream<Bool>

    private var tokenContinuation: AsyncStream<TranscribedToken>.Continuation
    private var engineReadyContinuation: AsyncStream<Void>.Continuation
    private var vadActivityContinuation: AsyncStream<Bool>.Continuation

    private let whisperModelPath: String
    private let sileroModelPath: String

    // Opaque C context pointers — nil when models are not yet loaded.
    private var whisperCtx: UnsafeMutableRawPointer?
    private var vadCtx: UnsafeMutableRawPointer?

    // Per-session inference loop task.
    private var inferenceTask: Task<Void, Never>?

    init(whisperModelPath: String, sileroModelPath: String) {
        self.whisperModelPath = whisperModelPath
        self.sileroModelPath = sileroModelPath

        var tCont: AsyncStream<TranscribedToken>.Continuation!
        self.tokenStream = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { tCont = $0 }
        self.tokenContinuation = tCont

        var eCont: AsyncStream<Void>.Continuation!
        self.engineReadyStream = AsyncStream { eCont = $0 }
        self.engineReadyContinuation = eCont

        var vCont: AsyncStream<Bool>.Continuation!
        self.vadActivityStream = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { vCont = $0 }
        self.vadActivityContinuation = vCont
    }

    // MARK: - Session lifecycle

    func start(locale: Locale, audioProvider: (any AudioBufferProvider)? = nil) async throws {
        // Recreate per-session streams (single-consumer contract, mirrors AudioPipeline pattern).
        var tCont: AsyncStream<TranscribedToken>.Continuation!
        tokenStream = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { tCont = $0 }
        tokenContinuation = tCont

        var eCont: AsyncStream<Void>.Continuation!
        engineReadyStream = AsyncStream { eCont = $0 }
        engineReadyContinuation = eCont

        // Load contexts on first session or after a prior failure left them nil.
        if whisperCtx == nil {
            metalFailureCount = 0
            whisperCtx = cwhisper_init(whisperModelPath, true)
            if whisperCtx == nil {
                metalFailureCount += 1
                Self.logger.warning("WhisperCppBackend: GPU init failed (count \(self.metalFailureCount)), retrying CPU")
                whisperCtx = cwhisper_init(whisperModelPath, false)
            }
            guard whisperCtx != nil else {
                Self.logger.error("WhisperCppBackend: whisper model unavailable at \(self.whisperModelPath)")
                throw TranscriberBackendError.modelUnavailable
            }
        }

        if vadCtx == nil {
            vadCtx = cwhisper_vad_init(sileroModelPath, Self.inferenceThreads)
            guard vadCtx != nil else {
                cwhisper_free(whisperCtx)
                whisperCtx = nil
                Self.logger.error("WhisperCppBackend: Silero VAD unavailable at \(self.sileroModelPath)")
                throw TranscriberBackendError.modelUnavailable
            }
        }

        engineReadyContinuation.yield(())

        guard let provider = audioProvider else {
            Self.logger.error("WhisperCppBackend: no audio provider passed to start()")
            throw TranscriberBackendError.engineFailure(
                underlying: NSError(domain: "WhisperCppBackend", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "Audio provider not set"])
            )
        }

        let capturedLocale = locale
        inferenceTask = Task { [weak self] in
            await self?.runInferenceLoop(provider: provider, locale: capturedLocale)
        }
    }

    func stop() async {
        inferenceTask?.cancel()
        inferenceTask = nil
        tokenContinuation.finish()
        engineReadyContinuation.finish()
        // Contexts intentionally kept alive between sessions (engine-always-warm).
    }

    /// Frees the whisper.cpp and Silero VAD C contexts and finishes all streams.
    /// Must be called before process exit to prevent ggml_metal_device_free asserting
    /// that residency sets are non-empty (GGML_ASSERT([rsets->data count] == 0)).
    /// Call after stop() so the inference task is already cancelled.
    func shutdown() async {
        inferenceTask?.cancel()
        inferenceTask = nil
        if let ctx = whisperCtx {
            cwhisper_free(ctx)
            whisperCtx = nil
        }
        if let ctx = vadCtx {
            cwhisper_vad_free(ctx)
            vadCtx = nil
        }
        tokenContinuation.finish()
        engineReadyContinuation.finish()
        vadActivityContinuation.finish()
    }

    // MARK: - Inference loop

    private func runInferenceLoop(provider: any AudioBufferProvider, locale: Locale) async {
        var accumulated: [Float] = []
        var audioPositionMs = 0

        for await capturedBuffer in provider.bufferStream() {
            if Task.isCancelled { break }

            let mono = toMono(capturedBuffer)
            let samples16k = resampleLinear(mono, fromRate: capturedBuffer.sampleRate, toRate: 16_000.0)
            accumulated.append(contentsOf: samples16k)

            while accumulated.count >= Self.kLengthSamples {
                let chunk = Array(accumulated.prefix(Self.kLengthSamples))
                accumulated.removeFirst(Self.kLengthSamples)

                let chunkStartMs = audioPositionMs
                audioPositionMs += 1_000

                guard let vCtx = vadCtx, let wCtx = whisperCtx else { break }

                let hasVoice = cwhisper_vad_detect_speech_threshold(
                    vCtx, chunk, Int32(Self.kLengthSamples), Self.vadThreshold
                )
                vadActivityContinuation.yield(hasVoice)

                if hasVoice {
                    let langCode = locale.language.languageCode?.identifier ?? "en"
                    let ret = cwhisper_full(
                        wCtx, chunk, Int32(Self.kLengthSamples),
                        Self.inferenceThreads, langCode, false, nil, nil
                    )
                    guard ret == 0 else { continue }

                    let rawTokens = extractRawTokens(from: wCtx, audioSamplePositionMs: chunkStartMs)
                    let merged = WhisperCppBackend.mergeBpeTokens(rawTokens, audioSamplePositionMs: chunkStartMs)
                    for token in merged {
                        tokenContinuation.yield(token)
                    }
                }
            }
        }
    }

    // MARK: - Audio helpers

    private func toMono(_ buffer: CapturedAudioBuffer) -> [Float] {
        guard buffer.channelCount > 0, !buffer.samples.isEmpty else { return [] }
        if buffer.channelCount == 1 { return buffer.samples[0] }
        let frameCount = buffer.samples[0].count
        var mono = [Float](repeating: 0, count: frameCount)
        let scale = 1.0 / Float(buffer.channelCount)
        for ch in buffer.samples {
            for (i, s) in ch.enumerated() { mono[i] += s * scale }
        }
        return mono
    }

    // Linear interpolation resampler — sufficient quality for speech recognition.
    private func resampleLinear(_ samples: [Float], fromRate: Double, toRate: Double) -> [Float] {
        guard fromRate != toRate, !samples.isEmpty else { return samples }
        let ratio = fromRate / toRate
        let outputCount = Int(Double(samples.count) / ratio)
        guard outputCount > 0 else { return [] }
        return (0..<outputCount).map { i in
            let pos = Double(i) * ratio
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            guard idx + 1 < samples.count else { return samples[min(idx, samples.count - 1)] }
            return samples[idx] * (1 - frac) + samples[idx + 1] * frac
        }
    }

    // Reads all tokens from the whisper context after a successful cwhisper_full call.
    private func extractRawTokens(from ctx: UnsafeMutableRawPointer, audioSamplePositionMs: Int) -> [RawWhisperToken] {
        let nSegments = cwhisper_n_segments(ctx)
        var result: [RawWhisperToken] = []
        for seg in 0..<nSegments {
            let nTokens = cwhisper_n_tokens(ctx, seg)
            for tok in 0..<nTokens {
                guard let rawText = cwhisper_token_text(ctx, seg, tok) else { continue }
                let text = String(cString: rawText)
                let t0 = cwhisper_token_t0(ctx, seg, tok)
                let t1 = cwhisper_token_t1(ctx, seg, tok)
                let prob = cwhisper_token_prob(ctx, seg, tok)
                result.append(RawWhisperToken(text: text, t0Cs: t0, t1Cs: t1, prob: prob))
            }
        }
        return result
    }

    // MARK: - Pure static helpers (testable without a live CWhisper context)

    /// Merges BPE fragments into words, filters specials, applies confidence threshold,
    /// and converts centisecond timestamps to session-relative seconds.
    static func mergeBpeTokens(
        _ rawTokens: [RawWhisperToken],
        audioSamplePositionMs: Int
    ) -> [TranscribedToken] {
        let filtered = rawTokens.filter { !isSpecialToken($0.text) }
        guard !filtered.isEmpty else { return [] }

        var wordGroups: [[RawWhisperToken]] = []
        var current: [RawWhisperToken] = []
        for token in filtered {
            if token.text.hasPrefix(" ") && !current.isEmpty {
                wordGroups.append(current)
                current = []
            }
            current.append(token)
        }
        if !current.isEmpty { wordGroups.append(current) }

        var result: [TranscribedToken] = []
        for group in wordGroups {
            let text = group.enumerated().map { i, t in
                i == 0 ? String(t.text.drop(while: { $0 == " " })) : t.text
            }.joined()
            guard !text.isEmpty else { continue }

            let avgProb = group.map(\.prob).reduce(0, +) / Float(group.count)
            guard avgProb >= confidenceThreshold else { continue }

            let t0Cs = group.first!.t0Cs
            let t1Cs = group.last!.t1Cs
            let startTime = Double(audioSamplePositionMs + Int(t0Cs) * 10) / 1000.0
            let endTime   = Double(audioSamplePositionMs + Int(t1Cs) * 10) / 1000.0

            result.append(TranscribedToken(
                token: text,
                startTime: startTime,
                endTime: endTime,
                isFinal: true,
                audioSamplePositionMs: audioSamplePositionMs,
                confidence: avgProb
            ))
        }
        return result
    }

    /// Returns true for whisper special/control tokens ([_BEG_], [_TT_nnn], <|lang|>, etc.).
    static func isSpecialToken(_ text: String) -> Bool {
        (text.hasPrefix("[_") && text.hasSuffix("]")) ||
        (text.hasPrefix("<|") && text.hasSuffix("|>"))
    }
}
