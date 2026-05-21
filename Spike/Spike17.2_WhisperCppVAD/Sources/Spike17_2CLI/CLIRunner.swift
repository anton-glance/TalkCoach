import Foundation
@preconcurrency import AVFoundation
import Spike17_2

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

/// Load a mono 16 kHz Float32 audio file (supports .caf, .wav, .m4a).
/// Resamples + down-mixes as needed via AVAudioConverter.
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

private func writeCSV(events: [TokenEvent], to url: URL) throws {
    var lines = ["update_index,emission_ms,gap_from_previous_ms,text,is_confirmed,confidence"]
    for e in events {
        let escaped = e.text.replacingOccurrences(of: "\"", with: "\"\"")
        lines.append("\(e.updateIndex),\(e.emissionMs),\(e.gapFromPreviousMs),\"\(escaped)\",\(e.isConfirmed ? 1 : 0),\(e.confidence)")
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
    var c4FirstTokenMs: Double     // -1 if no token emitted
    var warmupInferenceMs: Double  // duration of first whisper_full call
    var sileroVadJitMs: Double     // duration of first VAD call
}

// ---- CLIRunner ----------------------------------------------------------------

public enum CLIRunner {

    public static func run(args: [String]) async -> Int32 {
        guard args.count >= 2 else { printUsage(); return 1 }
        let subcommand = args[1]

        // Parse simple key=value flags from remaining args
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

        let detector = StreamingWhisperVoiceDetector()
        do {
            try await detector.loadModels(whisperModelPath: modelPath, vadModelPath: vadPath)
        } catch {
            print("[error] model load failed: \(error)"); return 1
        }
        let rssAfterLoad = peakRSSMB()
        let metalInfo = "see loadModels output above"

        // 3 warm-up VAD calls on silence before timing (Risk A mitigation)
        let silenceBuf = [Float](repeating: 0, count: 2560)
        for _ in 0..<3 {
            _ = await detector.process(chunk: silenceBuf)
        }

        // Time first real VAD call
        let vadStart = Date()
        _ = await detector.process(chunk: silenceBuf)
        let sileroVadJitMs = Date().timeIntervalSince(vadStart) * 1_000

        // Load quiet_speech_pods.caf as bootstrap audio
        let spikeRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let recDir = spikeRoot.appendingPathComponent("recordings")
        let testFile = recDir.appendingPathComponent("quiet_speech_pods.caf")
        guard let pcm = try? loadAudio(url: testFile) else {
            print("[error] could not load \(testFile.path)")
            return 1
        }

        // Pass 1: JIT-cold warm-up run (triggers Metal graph compilation)
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
        print("[bootstrap] JIT-cold pass complete (\(String(format: "%.0f", warmupMs))ms) — running warm pass for C4...")

        // Pass 2: JIT-warm run — measure real C4
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

        let result = BootstrapResult(
            modelPath: modelPath,
            vadPath: vadPath,
            metalSystemInfo: metalInfo,
            rssAfterLoadMB: rssAfterLoad,
            rssAfterFirstInferenceMB: rssAfterInfer,
            c4FirstTokenMs: c4Ms,
            warmupInferenceMs: warmupMs,
            sileroVadJitMs: sileroVadJitMs
        )

        let data = try! JSONEncoder().encode(result)
        let outURL = URL(fileURLWithPath: outputPath)
        try! FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try! data.write(to: outURL)
        print("[bootstrap] written to \(outputPath)")
        print("  Metal info: \(metalInfo)")
        print("  RSS after load:     \(String(format: "%.1f", rssAfterLoad)) MB")
        print("  RSS after infer:    \(String(format: "%.1f", rssAfterInfer)) MB")
        print("  C4 first token:     \(c4Ms < 0 ? "no token" : "\(String(format: "%.0f", c4Ms)) ms")")
        print("  Warmup total:       \(String(format: "%.0f", warmupMs)) ms")
        print("  Silero VAD JIT:     \(String(format: "%.1f", sileroVadJitMs)) ms")
        return 0
    }

    // MARK: — run

    private static func cmdRun(flags: [String: String]) async -> Int32 {
        guard let recPath  = flags["--recording"] else { print("--recording required"); return 1 }
        guard let modelPath = flags["--model"]    else { print("--model required");     return 1 }
        guard let vadPath   = flags["--vad"]      else { print("--vad required");       return 1 }
        let outputPath = flags["--output"] ?? "results/out.csv"

        let detector = StreamingWhisperVoiceDetector()
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
        let chunkSize = 2560  // 160 ms @ 16 kHz
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

    private static func printUsage() {
        print("""
        Usage:
          Spike17_2CLI download --model small|medium
          Spike17_2CLI download --vad
          Spike17_2CLI bootstrap --model <path> --vad <path> [--output results/bootstrap.json]
          Spike17_2CLI run --recording <path> --model <path> --vad <path> [--output results/out.csv]
        """)
    }
}
