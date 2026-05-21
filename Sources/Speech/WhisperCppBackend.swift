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
/// start()/stop() may be called multiple times; the token stream stays alive across sessions.
actor WhisperCppBackend: TranscriberBackend {

    // Static properties in actors are not actor-isolated — accessible from any context.
    private static let logger = Logger(subsystem: "com.talkcoach.app", category: "speech")

    // Minimum average token probability for a merged word to be emitted downstream.
    static let confidenceThreshold: Float = 0.4

    // Number of CPU threads used for both whisper and Silero inference.
    private static let inferenceThreads: Int32 = 4

    // Counts GPU init failures within the current session. Reset to 0 at each session start
    // so that a transient Metal issue never permanently locks the backend to CPU.
    private(set) var metalFailureCount: Int = 0

    nonisolated let tokenStream: AsyncStream<TranscribedToken>
    nonisolated let engineReadyStream: AsyncStream<Void>

    // Continuations are actor-isolated; they are only yielded/finished from within start()/stop().
    private var tokenContinuation: AsyncStream<TranscribedToken>.Continuation
    private var engineReadyContinuation: AsyncStream<Void>.Continuation

    private let whisperModelPath: String
    private let sileroModelPath: String

    // Opaque C context pointers — nil when not in a session.
    private var whisperCtx: UnsafeMutableRawPointer?
    private var vadCtx: UnsafeMutableRawPointer?

    init(whisperModelPath: String, sileroModelPath: String) {
        self.whisperModelPath = whisperModelPath
        self.sileroModelPath = sileroModelPath

        var tCont: AsyncStream<TranscribedToken>.Continuation!
        self.tokenStream = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { tCont = $0 }
        self.tokenContinuation = tCont

        var eCont: AsyncStream<Void>.Continuation!
        self.engineReadyStream = AsyncStream { eCont = $0 }
        self.engineReadyContinuation = eCont
    }

    // MARK: - Session lifecycle

    func start(locale: Locale) async throws {
        // Always reset and retry GPU at session start — transient Metal failures should not
        // permanently lock the backend to CPU across separate user sessions.
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

        vadCtx = cwhisper_vad_init(sileroModelPath, Self.inferenceThreads)
        guard vadCtx != nil else {
            cwhisper_free(whisperCtx)
            whisperCtx = nil
            Self.logger.error("WhisperCppBackend: Silero VAD unavailable at \(self.sileroModelPath)")
            throw TranscriberBackendError.modelUnavailable
        }

        engineReadyContinuation.yield(())
        // Audio → whisper inference loop wired in sub-commit 4 (AudioPipeline integration).
    }

    func stop() async {
        if let ctx = whisperCtx {
            cwhisper_free(ctx)
            whisperCtx = nil
        }
        if let ctx = vadCtx {
            cwhisper_vad_free(ctx)
            vadCtx = nil
        }
        // Streams intentionally not finished — engine-always-warm design keeps them live
        // across sessions so downstream consumers can subscribe once for the app lifetime.
    }

    // MARK: - Pure static helpers (testable without a live CWhisper context)

    /// Merges BPE token fragments into words, filters special/control tokens, applies
    /// the confidence threshold, and converts centisecond timestamps to session-relative seconds.
    ///
    /// `audioSamplePositionMs` is the cumulative audio stream position (ms) at the start of
    /// the whisper inference call that produced `rawTokens`.
    static func mergeBpeTokens(
        _ rawTokens: [RawWhisperToken],
        audioSamplePositionMs: Int
    ) -> [TranscribedToken] {
        let filtered = rawTokens.filter { !isSpecialToken($0.text) }
        guard !filtered.isEmpty else { return [] }

        // Group BPE fragments into words. A token with a leading space begins a new word.
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
            // Strip the BPE word-boundary space from the first fragment, keep the rest as-is.
            let text = group.enumerated().map { i, t in
                i == 0 ? String(t.text.drop(while: { $0 == " " })) : t.text
            }.joined()
            guard !text.isEmpty else { continue }

            let avgProb = group.map(\.prob).reduce(0, +) / Float(group.count)
            guard avgProb >= confidenceThreshold else { continue }

            // startTime = (chunkOffsetMs + t0_centiseconds * 10ms) / 1000
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

    /// Returns true for whisper special/control tokens that should not be emitted downstream.
    /// Matches `[_BEG_]`, `[_TT_nnn]` timestamp tokens, and `<|lang|>` / `<|task|>` tokens.
    static func isSpecialToken(_ text: String) -> Bool {
        (text.hasPrefix("[_") && text.hasSuffix("]")) ||
        (text.hasPrefix("<|") && text.hasSuffix("|>"))
    }
}
