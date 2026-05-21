import Foundation
import os

private let logger = Logger(subsystem: "com.talkcoach.app", category: "speech")

// Raw token from the CWhisper bridge: text + centisecond timestamps + token probability.
struct RawWhisperToken {
    let text: String
    let t0Cs: Int64
    let t1Cs: Int64
    let prob: Float
}

actor WhisperCppBackend: TranscriberBackend {
    static let confidenceThreshold: Float = 0.4

    private(set) var metalFailureCount: Int = 0

    nonisolated let tokenStream: AsyncStream<TranscribedToken>
    nonisolated let engineReadyStream: AsyncStream<Void>

    private var tokenContinuation: AsyncStream<TranscribedToken>.Continuation
    private var engineReadyContinuation: AsyncStream<Void>.Continuation

    private let whisperModelPath: String
    private let sileroModelPath: String

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

    func start(locale: Locale) async throws {
        // stub — does not implement Metal retry or update metalFailureCount
        throw TranscriberBackendError.modelUnavailable
    }

    func stop() async {
        tokenContinuation.finish()
        engineReadyContinuation.finish()
    }

    // MARK: - Pure static helpers (testable without live CWhisper context)

    // Merges BPE tokens into words, computes session-offset timestamps, filters specials
    // and low-confidence words. stub returns empty.
    static func mergeBpeTokens(
        _ rawTokens: [RawWhisperToken],
        audioSamplePositionMs: Int
    ) -> [TranscribedToken] {
        []  // stub
    }

    // Returns true if the token text is a whisper special/control token.
    static func isSpecialToken(_ text: String) -> Bool {
        false  // stub
    }
}
