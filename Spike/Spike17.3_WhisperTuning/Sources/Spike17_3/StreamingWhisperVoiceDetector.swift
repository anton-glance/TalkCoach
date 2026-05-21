import Foundation
import CWhisper
import AVFoundation

// Fix 3: special token filter list. Any segment text that exactly equals one of
// these strings (trimmed) is dropped before emitting TokenEvent.
// kAloneFilter: dropped only when the entire output text equals this string.
// kTokenFilter: dropped token-by-token from the output.
private let kTokenFilter: Set<String> = [
    "[BLANK_AUDIO]", "[_BEG_]", "[_END_]", "[MUSIC]",
    "[NOISE]", "[SILENCE]", "[SOUND]", "(Music playing)",
    "[_TT_0.00]", "[_TT_1.00]", "[_TT_2.00]",
]
private let kAloneFilter: Set<String> = [
    "Thank you.", "Thank you!", "Thanks.", "You.", "you.",
]

// Callback context passed as void* to cwhisper_full.
// Filled synchronously during the blocking call (same thread), no actor isolation concern.
private final class InferenceCallbackCtx {
    var firstTokenDate: Date? = nil
    var segments: [(text: String, medianProb: Float)] = []
}

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
/// Fix 1: kLengthMs and vadThreshold are configurable at init time.
/// Fix 2: uses cwhisper_vad_detect_speech_threshold for per-chunk VAD.
/// Fix 3: special token filter applied before emitting.
/// Fix 4: tracks totalSamplesProcessed for audio-domain timestamp in TokenEvent.
public actor StreamingWhisperVoiceDetector {

    private let kStepMs:     Int
    private let kLengthMs:   Int   // Fix 1: configurable ring buffer length
    private let kKeepMs:     Int
    private let kSilenceMs:  Int
    private let kSampleRate: Int
    private let vadThreshold: Float  // Fix 2: per-init Silero threshold

    private var kStepSamples:    Int { kStepMs   * kSampleRate / 1_000 }
    private var kLengthSamples:  Int { kLengthMs * kSampleRate / 1_000 }
    private var kKeepSamples:    Int { kKeepMs   * kSampleRate / 1_000 }
    private var kSilenceSamples: Int { kSilenceMs * kSampleRate / 1_000 }

    nonisolated(unsafe) private var whisperCtx: UnsafeMutableRawPointer? = nil
    nonisolated(unsafe) private var vadCtx:     UnsafeMutableRawPointer? = nil

    private var ringBuffer: [Float] = []
    private var samplesSinceLastStep: Int = 0
    private var isSpeaking: Bool = false
    private var silentSamples: Int = 0

    private var sessionStart: Date = .now
    private var events: [TokenEvent] = []
    private var prevText: String = ""
    private var updateIndex: Int = 0

    // Fix 4: tracks total audio samples fed to the detector this session
    private var totalSamplesProcessed: Int = 0

    public private(set) var firstInferenceStartDate: Date? = nil
    public private(set) var firstTokenDate: Date? = nil

    public init(kLengthMs: Int = 1_000, vadThreshold: Float = 0.5) {
        self.kLengthMs    = kLengthMs
        self.vadThreshold = vadThreshold
        self.kStepMs      = 200
        self.kKeepMs      = 200
        self.kSilenceMs   = 300
        self.kSampleRate  = 16_000
    }

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
        print("[vad] Silero VAD loaded from \(vadModelPath), threshold=\(vadThreshold)")
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
        totalSamplesProcessed = 0
        firstInferenceStartDate = nil
        firstTokenDate = nil
    }

    deinit {
        if let ctx = whisperCtx { cwhisper_free(ctx) }
        if let ctx = vadCtx     { cwhisper_vad_free(ctx) }
    }

    // MARK: — Audio processing

    public func process(chunk: [Float]) -> [TokenEvent] {
        var emitted: [TokenEvent] = []
        guard let vctx = vadCtx else { return [] }

        // Fix 4: accumulate sample count before inference
        totalSamplesProcessed += chunk.count

        // Fix 2: use threshold-aware VAD
        let isSpeechNow = chunk.withUnsafeBufferPointer { buf in
            cwhisper_vad_detect_speech_threshold(vctx, buf.baseAddress, Int32(buf.count), vadThreshold)
        }

        ringBuffer.append(contentsOf: chunk)
        if ringBuffer.count > kLengthSamples {
            ringBuffer.removeFirst(ringBuffer.count - kLengthSamples)
        }

        if isSpeechNow {
            isSpeaking = true
            silentSamples = 0
        } else if isSpeaking {
            silentSamples += chunk.count
        }

        samplesSinceLastStep += chunk.count

        if isSpeaking && samplesSinceLastStep >= kStepSamples {
            samplesSinceLastStep = 0
            if let event = runInference(isConfirmed: false, samplesAtInference: totalSamplesProcessed) {
                emitted.append(event)
            }
        }

        if isSpeaking && silentSamples >= kSilenceSamples {
            isSpeaking = false
            silentSamples = 0
            if let event = runInference(isConfirmed: true, samplesAtInference: totalSamplesProcessed) {
                emitted.append(event)
            }
            if ringBuffer.count > kKeepSamples {
                ringBuffer = Array(ringBuffer.suffix(kKeepSamples))
            }
        }

        return emitted
    }

    public func finish() -> [TokenEvent] {
        guard isSpeaking || !ringBuffer.isEmpty else { return [] }
        var out: [TokenEvent] = []
        if let event = runInference(isConfirmed: true, samplesAtInference: totalSamplesProcessed) {
            out.append(event)
        }
        isSpeaking = false
        return out
    }

    public func allEvents() -> [TokenEvent] { events }

    // MARK: — Private

    private func runInference(isConfirmed: Bool, samplesAtInference: Int) -> TokenEvent? {
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
                true,
                kSegmentCallback,
                retained.toOpaque()
            )
        }

        guard result == 0 else {
            print("[whisper] cwhisper_full returned \(result)")
            return nil
        }

        if firstTokenDate == nil, let t = cbCtx.firstTokenDate {
            firstTokenDate = t
        }

        // Fix 3: apply special token filter
        let rawText = cbCtx.segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let filteredText = applyTokenFilter(rawText)
        guard !filteredText.isEmpty, filteredText != prevText || isConfirmed else { return nil }

        let emissionMs = Date().timeIntervalSince(sessionStart) * 1_000
        let prevMs = events.last?.emissionMs ?? 0
        let gap = events.isEmpty ? emissionMs : emissionMs - prevMs
        let medianProb: Float = cbCtx.segments.isEmpty ? -1 :
            cbCtx.segments.map(\.medianProb).reduce(0, +) / Float(cbCtx.segments.count)

        // Fix 4: audio-domain timestamp
        let audioMs = samplesAtInference * 1_000 / kSampleRate

        let event = TokenEvent(
            updateIndex:            updateIndex,
            emissionMs:             emissionMs,
            gapFromPreviousMs:      gap,
            audioSamplePositionMs:  audioMs,
            text:                   filteredText,
            isConfirmed:            isConfirmed,
            confidence:             medianProb
        )
        events.append(event)
        updateIndex += 1
        prevText = filteredText
        return event
    }

    // Fix 3: filter implementation
    private func applyTokenFilter(_ input: String) -> String {
        // Drop entire output if it matches a standalone-only phrase
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if kAloneFilter.contains(trimmed) { return "" }

        // Remove token-level special markers from the text
        var result = trimmed
        for token in kTokenFilter {
            result = result.replacingOccurrences(of: token, with: "")
        }
        result = result.trimmingCharacters(in: .whitespaces)
        return result
    }
}

public enum DetectorError: Error {
    case whisperInitFailed(path: String)
    case vadInitFailed(path: String)
    case audioLoadFailed(url: URL)
}
