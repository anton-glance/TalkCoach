import Foundation
@preconcurrency import AVFoundation
import Spike17_3

// ---- RSS measurement -----------------------------------------------------------

private func peakRSSMB() -> Double {
    var info = task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size / MemoryLayout<integer_t>.size)
    let kr: kern_return_t = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return -1 }
    return Double(info.resident_size) / 1_048_576.0
}

// ---- Audio loading -------------------------------------------------------------

private func loadAudio(url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    let capacity = AVAudioFrameCount(
        Double(file.length) * 16_000 / file.fileFormat.sampleRate + 16_000
    )
    let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)!
    let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat)!
    let inputBuf = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: AVAudioFrameCount(file.length)
    )!
    try file.read(into: inputBuf)
    var error: NSError?
    converter.convert(to: outBuf, error: &error) { _, outStatus in
        outStatus.pointee = .haveData
        return inputBuf
    }
    if let err = error { throw err }
    let ptr = outBuf.floatChannelData![0]
    return Array(UnsafeBufferPointer(start: ptr, count: Int(outBuf.frameLength)))
}

// ---- CSV writing ---------------------------------------------------------------
// Columns: update_index, emission_ms, gap_from_previous_ms, audio_sample_position_ms,
//          text (quoted), is_confirmed, confidence

private func writeCSV(events: [TokenEvent], to url: URL) throws {
    var lines = ["update_index,emission_ms,gap_from_previous_ms,audio_sample_position_ms,text,is_confirmed,confidence"]
    for e in events {
        let escaped = e.text.replacingOccurrences(of: "\"", with: "\"\"")
        lines.append(
            "\(e.updateIndex),\(e.emissionMs),\(e.gapFromPreviousMs),\(e.audioSamplePositionMs)," +
            "\"\(escaped)\",\(e.isConfirmed ? 1 : 0),\(e.confidence)"
        )
    }
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
}

// ---- Bootstrap JSON ------------------------------------------------------------

private struct BootstrapResult: Codable {
    var modelPath: String
    var vadPath: String
    var metalSystemInfo: String
    var rssAfterLoadMB: Double
    var rssAfterFirstInferenceMB: Double
    var c4FirstTokenMs: Double          // warm C4 on quiet_speech_pods.caf (primary)
    var c4CrossCheckMs: Double          // warm C4 on quiet_speech_mac.caf (Revision 2 cross-check)
    var warmupInferenceMs: Double
    var sileroVadJitMs: Double
    var kLengthMs: Int
    var vadThreshold: Float
    var medianLogProb: Double           // for C9 baseline (smoke baseline JSON key)
    var smokePodC4: Double              // alias: same as c4FirstTokenMs
    var smokeMacC4: Double              // alias: same as c4CrossCheckMs
    var smokePassWithCaveat: Bool       // true if mac C4 > 1.5× pods C4
    var smokeCleanPass: Bool            // true if both pods AND mac C4 ≤ 200ms
}

// Fix 5: fixture verification list
private let kExpectedFixtures: [String] = [
    "alternating_pods.caf", "alternating_mac.caf",
    "quiet_speech_pods.caf", "quiet_speech_mac.caf",
    "cafe_noise_pods.caf", "cafe_noise_mac.caf",
    "silence_only_pods.caf", "silence_only_mac.caf",
    "distractors_pods.caf", "distractors_mac.caf",
    "real_world_test.caf",
]

// ---- CLIRunner ----------------------------------------------------------------

public enum CLIRunner {

    public static func run(args: [String]) async -> Int32 {
        guard args.count >= 2 else { printUsage(); return 1 }
        let subcommand = args[1]

        var flags: [String: String] = [:]
        var i = 2
        while i < args.count {
            if args[i].hasPrefix("--"), i + 1 < args.count {
                flags[args[i]] = args[i + 1]
                i += 2
            } else {
                i += 1
            }
        }

        switch subcommand {
        case "download":
            return await cmdDownload(flags: flags)
        case "bootstrap":
            return await cmdBootstrap(flags: flags)
        case "run":
            return await cmdRun(flags: flags)
        default:
            printUsage()
            return 1
        }
    }

    // MARK: — download

    private static func cmdDownload(flags: [String: String]) async -> Int32 {
        let spikeRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let modelsDir = spikeRoot.appendingPathComponent("models")
        do {
            if flags["--vad"] != nil || flags["--model"] == nil {
                try await WhisperModelLoader.downloadVAD(modelsDir: modelsDir)
            }
            if let model = flags["--model"] {
                guard let size = ModelSize(rawValue: model) else {
                    print("Unknown model '\(model)'. Use: small, medium"); return 1
                }
                try await WhisperModelLoader.downloadWhisper(size: size, modelsDir: modelsDir)
            }
        } catch {
            print("[error] download failed: \(error)")
            return 1
        }
        return 0
    }

    // MARK: — bootstrap

    private static func cmdBootstrap(flags: [String: String]) async -> Int32 {
        guard let modelPath = flags["--model"] else { print("--model required"); return 1 }
        guard let vadPath   = flags["--vad"]   else { print("--vad required");   return 1 }
        let outputPath = flags["--output"] ?? "results/bootstrap.json"
        let kLengthMs  = Int(flags["--k-length-ms"] ?? "1000") ?? 1000
        let vadThreshold: Float = resolveVadThreshold(flags: flags)

        // Fix 5: verify all fixtures present before any processing
        let spikeRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let recDir = spikeRoot.appendingPathComponent("recordings")
        for fixture in kExpectedFixtures {
            let path = recDir.appendingPathComponent(fixture).path
            if !FileManager.default.fileExists(atPath: path) {
                print("[error] missing fixture: \(path)")
                return 1
            }
        }
        print("[bootstrap] all \(kExpectedFixtures.count) fixtures verified")

        let detector = StreamingWhisperVoiceDetector(kLengthMs: kLengthMs, vadThreshold: vadThreshold)
        do {
            try await detector.loadModels(whisperModelPath: modelPath, vadModelPath: vadPath)
        } catch {
            print("[error] model load failed: \(error)"); return 1
        }
        let rssAfterLoad = peakRSSMB()
        let metalInfo = "see loadModels output above"

        // Warm-up VAD
        let silenceBuf = [Float](repeating: 0, count: 2560)
        for _ in 0..<3 { _ = await detector.process(chunk: silenceBuf) }
        let vadStart = Date()
        _ = await detector.process(chunk: silenceBuf)
        let sileroVadJitMs = Date().timeIntervalSince(vadStart) * 1_000

        let testFile = recDir.appendingPathComponent("quiet_speech_pods.caf")
        guard let pcm = try? loadAudio(url: testFile) else {
            print("[error] could not load \(testFile.path)"); return 1
        }

        // Pass 1: JIT-cold warm-up
        await detector.reset()
        let warmupStart = Date()
        let chunkSize = 2560
        var idx = 0
        while idx < pcm.count {
            let end = min(idx + chunkSize, pcm.count)
            _ = await detector.process(chunk: Array(pcm[idx..<end]))
            idx = end
        }
        _ = await detector.finish()
        let warmupMs = Date().timeIntervalSince(warmupStart) * 1_000
        print("[bootstrap] JIT-cold pass (\(String(format: "%.0f", warmupMs))ms) — running warm pass for C4...")

        // Pass 2: JIT-warm — measure C4
        await detector.reset()
        idx = 0
        while idx < pcm.count {
            let end = min(idx + chunkSize, pcm.count)
            _ = await detector.process(chunk: Array(pcm[idx..<end]))
            idx = end
        }
        _ = await detector.finish()

        let firstInferStart = await detector.firstInferenceStartDate
        let firstTokDate    = await detector.firstTokenDate
        let c4Ms: Double
        if let s = firstInferStart, let t = firstTokDate {
            c4Ms = t.timeIntervalSince(s) * 1_000
        } else {
            c4Ms = -1
        }
        let rssAfterInfer = peakRSSMB()

        // Compute smoke baseline median log_prob from all events on pass 2
        let allEvents = await detector.allEvents()
        let confirmedConf = allEvents.filter { $0.isConfirmed && $0.confidence >= 0 }.map(\.confidence)
        let sortedConf = confirmedConf.sorted()
        let medianLogProb = sortedConf.isEmpty ? -1.0 : Double(sortedConf[sortedConf.count / 2])

        // Revision 2 cross-check: run a warm pass on quiet_speech_mac.caf at mac threshold (0.3)
        // C4 is encoder latency (fixture-independent once VAD fires), but this validates
        // that per-fixture C4 variance is within expected range.
        print("[bootstrap] running Revision 2 cross-check on quiet_speech_mac.caf...")
        let macFile = recDir.appendingPathComponent("quiet_speech_mac.caf")
        var c4CrossCheckMs: Double = -1
        if let macPcm = try? loadAudio(url: macFile) {
            let macDetector = StreamingWhisperVoiceDetector(kLengthMs: kLengthMs, vadThreshold: 0.3)
            if let _ = try? await macDetector.loadModels(whisperModelPath: modelPath, vadModelPath: vadPath) as Void? {
                // Single warm pass (model was already JIT-warmed by the pods bootstrap above)
                var macIdx = 0
                while macIdx < macPcm.count {
                    let end = min(macIdx + 2560, macPcm.count)
                    _ = await macDetector.process(chunk: Array(macPcm[macIdx..<end]))
                    macIdx = end
                }
                _ = await macDetector.finish()
                if let s = await macDetector.firstInferenceStartDate,
                   let t = await macDetector.firstTokenDate {
                    c4CrossCheckMs = t.timeIntervalSince(s) * 1_000
                }
            }
        }
        let smokePodC4 = c4Ms
        let smokeMacC4 = c4CrossCheckMs
        let smokePassWithCaveat = (c4CrossCheckMs > 0 && c4Ms > 0) ? (c4CrossCheckMs > 1.5 * c4Ms) : false
        let smokeCleanPass = (c4Ms >= 0 && c4Ms <= 200) && (c4CrossCheckMs >= 0 && c4CrossCheckMs <= 200)

        let result = BootstrapResult(
            modelPath: modelPath,
            vadPath: vadPath,
            metalSystemInfo: metalInfo,
            rssAfterLoadMB: rssAfterLoad,
            rssAfterFirstInferenceMB: rssAfterInfer,
            c4FirstTokenMs: c4Ms,
            c4CrossCheckMs: c4CrossCheckMs,
            warmupInferenceMs: warmupMs,
            sileroVadJitMs: sileroVadJitMs,
            kLengthMs: kLengthMs,
            vadThreshold: vadThreshold,
            medianLogProb: medianLogProb,
            smokePodC4: smokePodC4,
            smokeMacC4: smokeMacC4,
            smokePassWithCaveat: smokePassWithCaveat,
            smokeCleanPass: smokeCleanPass
        )

        let data = try! JSONEncoder().encode(result)
        let outURL = URL(fileURLWithPath: outputPath)
        try! FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try! data.write(to: outURL)
        print("[bootstrap] written to \(outputPath)")
        print("  kLengthMs: \(kLengthMs)")
        print("  vadThreshold (pods): \(vadThreshold)")
        print("  RSS after load:      \(String(format: "%.1f", rssAfterLoad)) MB")
        print("  RSS after infer:     \(String(format: "%.1f", rssAfterInfer)) MB")
        print("  C4 pods (primary):   \(c4Ms < 0 ? "no token" : "\(String(format: "%.0f", c4Ms)) ms")")
        print("  C4 mac (cross-check):\(c4CrossCheckMs < 0 ? " no token" : " \(String(format: "%.0f", c4CrossCheckMs)) ms")")
        print("  smokeCleanPass:      \(smokeCleanPass)  (both C4 ≤ 200ms)")
        print("  smokePassWithCaveat: \(smokePassWithCaveat)  (mac C4 > 1.5× pods C4)")
        print("  Warmup total:        \(String(format: "%.0f", warmupMs)) ms")
        print("  Silero VAD JIT:      \(String(format: "%.1f", sileroVadJitMs)) ms")
        print("  Smoke baseline log_prob: \(String(format: "%.3f", medianLogProb))")
        return 0
    }

    // MARK: — run

    private static func cmdRun(flags: [String: String]) async -> Int32 {
        guard let recPath   = flags["--recording"] else { print("--recording required"); return 1 }
        guard let modelPath = flags["--model"]     else { print("--model required");     return 1 }
        guard let vadPath   = flags["--vad"]       else { print("--vad required");       return 1 }
        let outputPath   = flags["--output"] ?? "results/out.csv"
        let kLengthMs    = Int(flags["--k-length-ms"] ?? "1000") ?? 1000
        let vadThreshold: Float = resolveVadThreshold(flags: flags)

        let detector = StreamingWhisperVoiceDetector(kLengthMs: kLengthMs, vadThreshold: vadThreshold)
        do {
            try await detector.loadModels(whisperModelPath: modelPath, vadModelPath: vadPath)
        } catch {
            print("[error] model load: \(error)"); return 1
        }

        let recURL = URL(fileURLWithPath: recPath)
        guard let pcm = try? loadAudio(url: recURL) else {
            print("[error] could not load \(recPath)"); return 1
        }

        await detector.reset()
        let chunkSize = 2560
        var idx = 0
        while idx < pcm.count {
            let end = min(idx + chunkSize, pcm.count)
            _ = await detector.process(chunk: Array(pcm[idx..<end]))
            idx = end
        }
        _ = await detector.finish()

        let allEvents = await detector.allEvents()
        let c4Ms: Double
        if let s = await detector.firstInferenceStartDate,
           let t = await detector.firstTokenDate {
            c4Ms = t.timeIntervalSince(s) * 1_000
        } else {
            c4Ms = -1
        }

        let outURL = URL(fileURLWithPath: outputPath)
        try! FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            try writeCSV(events: allEvents, to: outURL)
        } catch {
            print("[error] CSV write: \(error)"); return 1
        }

        print("[run] \(recURL.lastPathComponent) → \(allEvents.count) events, C4=\(c4Ms < 0 ? "N/A" : "\(Int(c4Ms))ms"), output: \(outputPath)")
        return 0
    }

    // MARK: — helpers

    /// Resolve VAD threshold from flags.
    /// --vad-threshold takes priority; --mic-profile pods=0.5, mac=0.3.
    /// Default: 0.5.
    private static func resolveVadThreshold(flags: [String: String]) -> Float {
        if let explicit = flags["--vad-threshold"], let v = Float(explicit) {
            return v
        }
        switch flags["--mic-profile"] {
        case "mac":  return 0.3
        case "pods": return 0.5
        default:     return 0.5
        }
    }

    private static func printUsage() {
        print("""
        Usage:
          Spike17_3CLI download --model small|medium
          Spike17_3CLI download --vad
          Spike17_3CLI bootstrap --model <path> --vad <path> [--output results/bootstrap.json]
                                 [--k-length-ms 1000] [--mic-profile pods|mac | --vad-threshold 0.5]
          Spike17_3CLI run --recording <path> --model <path> --vad <path> [--output results/out.csv]
                           [--k-length-ms 1000] [--mic-profile pods|mac | --vad-threshold 0.5]
        """)
    }
}
