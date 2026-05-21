import Foundation
import CWhisper
import AVFoundation

// --- Callback context -----------------------------------------------------------
// Passed as void* user_data to cwhisper_full. Filled synchronously during the
// blocking call (same thread), so no actor isolation concern.

private final class InferenceCallbackCtx {
    var firstTokenDate: Date? = nil
    var segments: [(text: String, medianProb: Float)] = []
}

// Non-capturing C callback. user_data is a retained InferenceCallbackCtx.
// Fired by WhisperBridge.c's whisper_segment_bridge on each new segment.
private let kSegmentCallback: CWhisperSegmentCallback = { ctx, nNew, userData in
    guard let ctx, let userData else { return }
    let cbCtx = Unmanaged<InferenceCallbackCtx>.fromOpaque(userData).takeUnretainedValue()
    if cbCtx.firstTokenDate == nil {
        cbCtx.firstTokenDate = Date()
    }
    let total = cwhisper_n_segments(ctx)
    let start = Int(total) - Int(nNew)
    for i in start..<Int(total) {
        guard let raw = cwhisper_segment_text(ctx, Int32(i)) else { continue }
        let text = String(cString: raw).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { continue }
        let nTok = cwhisper_n_tokens(ctx, Int32(i))
        var probSum: Float = 0
        for t in 0..<nTok {
            probSum += cwhisper_token_prob(ctx, Int32(i), t)
        }
        let median = nTok > 0 ? probSum / Float(nTok) : 0
        cbCtx.segments.append((text, median))
    }
}

// -------------------------------------------------------------------------------

/// Streaming whisper.cpp + Silero VAD voice detector.
/// Feeds audio in chunks; fires cwhisper_full every kStepMs while speech detected.
public actor StreamingWhisperVoiceDetector {

    private let kStepMs:      Int = 200
    private let kLengthMs:    Int = 3_000
    private let kKeepMs:      Int = 200
    private let kSilenceMs:   Int = 300
    private let kSampleRate:  Int = 16_000

    private var kStepSamples:   Int { kStepMs   * kSampleRate / 1_000 }
    private var kLengthSamples: Int { kLengthMs * kSampleRate / 1_000 }
    private var kKeepSamples:   Int { kKeepMs   * kSampleRate / 1_000 }
    private var kSilenceSamples: Int { kSilenceMs * kSampleRate / 1_000 }

    // C context handles (opaque C types freed in deinit).
    // nonisolated(unsafe) allows deinit access; safe because only this actor writes them.
    nonisolated(unsafe) private var whisperCtx: UnsafeMutableRawPointer? = nil
    nonisolated(unsafe) private var vadCtx:     UnsafeMutableRawPointer? = nil

    // Session state
    private var ringBuffer: [Float] = []
    private var samplesSinceLastStep: Int = 0
    private var isSpeaking: Bool = false
    private var silentSamples: Int = 0

    private var sessionStart: Date = .now
    private var events: [TokenEvent] = []
    private var prevText: String = ""
    private var updateIndex: Int = 0

    // C4 measurement
    public private(set) var firstInferenceStartDate: Date? = nil
    public private(set) var firstTokenDate: Date? = nil

    public init() {}

    // MARK: — Lifecycle

    public func loadModels(whisperModelPath: String, vadModelPath: String) throws {
        let wctx = cwhisper_init(whisperModelPath, true)
        guard let wctx else {
            throw DetectorError.whisperInitFailed(path: whisperModelPath)
        }
        self.whisperCtx = wctx
        if let info = cwhisper_system_info() {
            print("[whisper] system info: \(String(cString: info))")
        }

        let vctx = cwhisper_vad_init(
            vadModelPath,
            Int32(min(4, ProcessInfo.processInfo.processorCount))
        )
        guard let vctx else {
            throw DetectorError.vadInitFailed(path: vadModelPath)
        }
        self.vadCtx = vctx
        print("[vad] Silero VAD loaded from \(vadModelPath)")
    }

    public func reset() {
        ringBuffer = []
        samplesSinceLastStep = 0
        isSpeaking = false
        silentSamples = 0
        sessionStart = .now
        events = []
        prevText = ""
        updateIndex = 0
        firstInferenceStartDate = nil
        firstTokenDate = nil
    }

    deinit {
        if let ctx = whisperCtx { cwhisper_free(ctx) }
        if let ctx = vadCtx     { cwhisper_vad_free(ctx) }
    }

    // MARK: — Audio processing

    /// Feed one chunk of Float32 mono 16 kHz PCM.
    /// Returns all TokenEvents emitted during this chunk.
    public func process(chunk: [Float]) -> [TokenEvent] {
        var emitted: [TokenEvent] = []
        guard let vctx = vadCtx else { return [] }

        // Silero VAD on this chunk
        let isSpeechNow = chunk.withUnsafeBufferPointer { buf in
            cwhisper_vad_detect_speech(vctx, buf.baseAddress, Int32(buf.count))
        }

        // Update ring buffer (sliding window)
        ringBuffer.append(contentsOf: chunk)
        if ringBuffer.count > kLengthSamples {
            ringBuffer.removeFirst(ringBuffer.count - kLengthSamples)
        }

        // Speech state tracking
        if isSpeechNow {
            if !isSpeaking {
                isSpeaking = true
                silentSamples = 0
            } else {
                silentSamples = 0
            }
        } else if isSpeaking {
            silentSamples += chunk.count
        }

        samplesSinceLastStep += chunk.count

        // Trigger step inference while speaking
        if isSpeaking && samplesSinceLastStep >= kStepSamples {
            samplesSinceLastStep = 0
            if let event = runInference(isConfirmed: false) {
                emitted.append(event)
            }
        }

        // Confirm EOS after sustained silence
        if isSpeaking && silentSamples >= kSilenceSamples {
            isSpeaking = false
            silentSamples = 0
            if let event = runInference(isConfirmed: true) {
                emitted.append(event)
            }
            if ringBuffer.count > kKeepSamples {
                ringBuffer = Array(ringBuffer.suffix(kKeepSamples))
            }
        }

        return emitted
    }

    /// Flush remaining audio as a final confirmed segment.
    public func finish() -> [TokenEvent] {
        guard isSpeaking || !ringBuffer.isEmpty else { return [] }
        var out: [TokenEvent] = []
        if let event = runInference(isConfirmed: true) {
            out.append(event)
        }
        isSpeaking = false
        return out
    }

    public func allEvents() -> [TokenEvent] { events }

    // MARK: — Private

    private func runInference(isConfirmed: Bool) -> TokenEvent? {
        guard let ctx = whisperCtx, !ringBuffer.isEmpty else { return nil }

        let cbCtx = InferenceCallbackCtx()
        let retained = Unmanaged.passRetained(cbCtx)
        defer { retained.release() }

        let inferStart = Date()
        if firstInferenceStartDate == nil {
            firstInferenceStartDate = inferStart
        }

        let nThreads = Int32(min(4, ProcessInfo.processInfo.processorCount))
        let result = ringBuffer.withUnsafeBufferPointer { buf in
            cwhisper_full(
                ctx,
                buf.baseAddress,
                Int32(buf.count),
                nThreads,
                "en",
                true,   // no_timestamps
                kSegmentCallback,
                retained.toOpaque()
            )
        }

        guard result == 0 else {
            print("[whisper] cwhisper_full returned \(result)")
            return nil
        }

        // Record C4 first-token date
        if firstTokenDate == nil, let t = cbCtx.firstTokenDate {
            firstTokenDate = t
        }

        let fullText = cbCtx.segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !fullText.isEmpty, fullText != prevText || isConfirmed else { return nil }

        let emissionMs = Date().timeIntervalSince(sessionStart) * 1_000
        let prevMs = events.last?.emissionMs ?? 0
        let gap = events.isEmpty ? emissionMs : emissionMs - prevMs
        let medianProb: Float = cbCtx.segments.isEmpty ? -1 :
            cbCtx.segments.map(\.medianProb).reduce(0, +) / Float(cbCtx.segments.count)

        let event = TokenEvent(
            updateIndex:       updateIndex,
            emissionMs:        emissionMs,
            gapFromPreviousMs: gap,
            text:              fullText,
            isConfirmed:       isConfirmed,
            confidence:        medianProb
        )
        events.append(event)
        updateIndex += 1
        prevText = fullText
        return event
    }
}

public enum DetectorError: Error {
    case whisperInitFailed(path: String)
    case vadInitFailed(path: String)
    case audioLoadFailed(url: URL)
}
