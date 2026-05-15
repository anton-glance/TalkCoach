// Spike 14 — SpeechAnalyzer warm-state survival across AVAudioEngine teardown
//
// Hypothesis: the same AsyncStream<AnalyzerInput>.Continuation can survive
// engine1.stop() → fresh engine2 instantiation → tap reinstall, with the
// SpeechAnalyzer/SpeechTranscriber pair continuing to emit tokens without
// a 5-7s warm-up gap.
//
// The key invariant: inputContinuation.finish() is NOT called between phases.
// The SpeechAnalyzer's start(inputSequence:) task keeps running, blocked
// waiting for the next AnalyzerInput. When engine2's tap fires, it yields
// to the same continuation — resuming the analysis.

@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation

// Disable stdout block-buffering so prints flush immediately even when redirected.
setbuf(stdout, nil)

// MARK: - Shared state (nonisolated(unsafe) — spike only, not production pattern)

let gStartNs = DispatchTime.now().uptimeNanoseconds

func wallMs() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - gStartNs) / 1_000_000.0
}

nonisolated(unsafe) var gPhase = 1
nonisolated(unsafe) var gPhase1Count = 0
nonisolated(unsafe) var gPhase1FirstMs: Double? = nil
nonisolated(unsafe) var gPhase2Count = 0
nonisolated(unsafe) var gPhase2FirstMs: Double? = nil
nonisolated(unsafe) var gPhase2StartMs: Double = 0.0
nonisolated(unsafe) var gInputCont: AsyncStream<AnalyzerInput>.Continuation?
nonisolated(unsafe) var gAnalyzerFormat: AVAudioFormat? = nil
nonisolated(unsafe) var gConverter: AVAudioConverter? = nil

// MARK: - Entry point

DispatchQueue.main.async {
    Task {
        await runSpike14()
        exit(0)
    }
}
dispatchMain()

// MARK: - Spike logic

func runSpike14() async {
    print("=== SPIKE 14: SpeechAnalyzer warm-state survival across AVAudioEngine teardown ===")
    print("API: SpeechAnalyzer + SpeechTranscriber (macOS 26)")
    print("Test: same inputContinuation kept alive across engine stop/rebuild\n")
    print("Requesting microphone access...")

    let granted = await AVCaptureDevice.requestAccess(for: .audio)
    guard granted else {
        print("ERROR: Microphone access denied. Grant in System Settings > Privacy > Microphone.")
        return
    }
    print("Microphone access granted.\n")

    // --- Transcriber + input stream ---

    let transcriber = SpeechTranscriber(
        locale: Locale(identifier: "en-US"),
        transcriptionOptions: [],
        reportingOptions: [.volatileResults],
        attributeOptions: [.audioTimeRange]
    )

    let (inputStream, inputCont) = AsyncStream.makeStream(of: AnalyzerInput.self)
    gInputCont = inputCont

    // --- Phase 1 engine (needed before analyzer setup to get hardware format) ---

    let engine1 = AVAudioEngine()
    let inputNode1 = engine1.inputNode
    let hwFormat1 = inputNode1.outputFormat(forBus: 0)

    guard hwFormat1.sampleRate > 0, hwFormat1.channelCount > 0 else {
        print("ERROR: No audio input detected (sampleRate=\(hwFormat1.sampleRate)). Plug in a mic.")
        return
    }
    print("Hardware input format: \(hwFormat1.sampleRate)Hz \(hwFormat1.channelCount)ch")

    // --- Analyzer format ---

    let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
        compatibleWith: [transcriber], considering: hwFormat1
    )
    let analyzerFormat = targetFormat ?? hwFormat1
    gAnalyzerFormat = analyzerFormat
    print("Analyzer target format: \(analyzerFormat.sampleRate)Hz \(analyzerFormat.channelCount)ch")

    if let tf = targetFormat, tf.sampleRate != hwFormat1.sampleRate {
        gConverter = AVAudioConverter(from: hwFormat1, to: tf)
        print("Sample-rate conversion enabled: \(hwFormat1.sampleRate) → \(tf.sampleRate)")
    }

    // --- Result consumer task ---
    // Reads from transcriber.results for the lifetime of both phases.

    let resultTask = Task {
        do {
            for try await result in transcriber.results {
                let ms = wallMs()
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                if gPhase == 1 {
                    if gPhase1FirstMs == nil { gPhase1FirstMs = ms }
                    gPhase1Count += 1
                    print(String(format: "[+%.2fs] p1 \"%@\" final=%@",
                                 ms / 1000.0, text, result.isFinal ? "true" : "false"))
                } else {
                    let rel = ms - gPhase2StartMs
                    if gPhase2FirstMs == nil { gPhase2FirstMs = rel }
                    gPhase2Count += 1
                    print(String(format: "[+%.2fs | +%.2fs post-rebuild] p2 \"%@\" final=%@",
                                 ms / 1000.0, rel / 1000.0, text, result.isFinal ? "true" : "false"))
                }
            }
        } catch {
            print("[result stream error: \(error)]")
        }
        print("[result stream ended]")
    }

    // --- Analyzer: prepareToAnalyze + start ---
    // start(inputSequence:) sets up internal async consumers and returns;
    // it does NOT block until the stream ends (production feedTask proves this —
    // the same task both calls start and later yields to inputContinuation).

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    do {
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try await analyzer.start(inputSequence: inputStream)
    } catch {
        print("ERROR: SpeechAnalyzer setup failed: \(error)")
        gInputCont?.finish()
        return
    }
    print("SpeechAnalyzer started.\n")

    // --- Phase 1: engine1 running, tap flowing to inputContinuation ---

    installTap(on: inputNode1)
    do {
        try engine1.start()
    } catch {
        print("ERROR: engine1.start() failed: \(error)")
        gInputCont?.finish()
        return
    }

    print("=== PHASE 1 START === (wallMs=\(Int(wallMs())))")
    print("Speak now — running 30 seconds...")
    try? await Task.sleep(for: .seconds(30))

    // --- Phase 2: stop engine1, wait, rebuild with engine2 ---
    // The critical invariant: gInputCont is NOT finished here.

    print("\n=== PHASE 2 START — engine teardown + rebuild === (wallMs=\(Int(wallMs())))")
    inputNode1.removeTap(onBus: 0)
    engine1.stop()
    print("[engine1 stopped | inputContinuation NOT finished | same reference active]")

    print("[HAL settling — waiting 200ms]")
    try? await Task.sleep(for: .milliseconds(200))

    gPhase = 2
    gPhase2StartMs = wallMs()

    let engine2 = AVAudioEngine()
    let inputNode2 = engine2.inputNode
    let hwFormat2 = inputNode2.outputFormat(forBus: 0)

    if hwFormat2.sampleRate != hwFormat1.sampleRate || hwFormat2.channelCount != hwFormat1.channelCount {
        print("[Note: hardware format changed on rebuild: \(hwFormat2.sampleRate)Hz \(hwFormat2.channelCount)ch]")
        if let af = gAnalyzerFormat {
            gConverter = AVAudioConverter(from: hwFormat2, to: af)
        }
    }

    installTap(on: inputNode2)
    do {
        try engine2.start()
    } catch {
        print("ERROR: engine2.start() failed: \(error)")
        gInputCont?.finish()
        return
    }

    print("[engine2 started | new tap feeding SAME inputContinuation]")
    print("Speak now — running 30 seconds...")
    try? await Task.sleep(for: .seconds(30))

    // --- Phase 3: finish and drain ---

    print("\n=== PHASE 3: FINISHING === (wallMs=\(Int(wallMs())))")
    inputNode2.removeTap(onBus: 0)
    engine2.stop()
    gInputCont?.finish()
    gInputCont = nil

    try? await Task.sleep(for: .seconds(3))
    resultTask.cancel()

    // --- Determine outcome ---

    let p1Str = gPhase1FirstMs.map { String(format: "+%.2fs", $0 / 1000.0) } ?? "never"
    let p2Str: String
    let warmUpStr: String
    let hypothesis: String

    if let gap = gPhase2FirstMs, gPhase2Count > 0 {
        p2Str = String(format: "+%.2fs after rebuild", gap / 1000.0)
        if gap < 1_000 {
            warmUpStr = "NO"
            hypothesis = "SUPPORTED"
        } else if gap < 7_000 {
            warmUpStr = String(format: "YES (%.1fs)", gap / 1000.0)
            hypothesis = "PARTIAL"
        } else {
            warmUpStr = String(format: "YES (%.1fs — full cold-start)", gap / 1000.0)
            hypothesis = "REJECTED"
        }
    } else {
        p2Str = "never"
        warmUpStr = "N/A"
        hypothesis = "REJECTED"
    }

    print("""

    SPIKE 14 RESULT:
    Phase 1: first token at \(p1Str), total tokens: \(gPhase1Count)
    Phase 2 (after engine rebuild): first new token at \(p2Str), total tokens: \(gPhase2Count)
    Phase 3: tokens continued = \(gPhase2Count > 0 ? "YES" : "NO"), warm-up gap on rebuild = \(warmUpStr)
    HYPOTHESIS: \(hypothesis)
    """)
}

// MARK: - Tap helper

// Called from audio thread — accesses nonisolated(unsafe) globals intentionally.
nonisolated func installTap(on node: AVAudioInputNode) {
    node.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
        guard let cont = gInputCont,
              let af = gAnalyzerFormat else { return }

        let analyzerBuffer: AVAudioPCMBuffer
        if let conv = gConverter {
            let ratio = af.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: af, frameCapacity: capacity) else { return }
            var convErr: NSError?
            var consumed = false
            conv.convert(to: converted, error: &convErr) { _, status in
                if !consumed {
                    consumed = true
                    status.pointee = .haveData
                    return buffer
                }
                status.pointee = .noDataNow
                return nil
            }
            if convErr != nil { return }
            analyzerBuffer = converted
        } else {
            analyzerBuffer = buffer
        }

        cont.yield(AnalyzerInput(buffer: analyzerBuffer))
    }
}
