import AVFAudio
import FluidAudio
import Foundation
import Spike17_1_5

// MARK: - RSS helper

#if canImport(Darwin)
import Darwin

nonisolated func currentRSSMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    return Double(info.resident_size) / 1_048_576.0
}
#else
nonisolated func currentRSSMB() -> Double { return 0 }
#endif

// MARK: - Bootstrap result

struct BootstrapResult: Codable {
    let modelLoadSuccess: Bool
    let loadDurationMs: Double
    let peakRSSMB: Double
    let errorDescription: String?
}

func writeBootstrap(_ result: BootstrapResult, to path: String) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(result) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

// MARK: - CSV output

func writeCSV(_ events: [TokenEvent], to path: String) throws {
    var lines = ["update_index,emission_ms,gap_from_previous_ms,text,is_confirmed,confidence"]
    for e in events {
        let safeText = e.text
            .replacingOccurrences(of: "\"", with: "\"\"")
            .replacingOccurrences(of: "\n", with: " ")
        lines.append(
            "\(e.updateIndex),"
            + "\(String(format: "%.1f", e.emissionMs)),"
            + "\(String(format: "%.1f", e.gapFromPreviousMs)),"
            + "\"\(safeText)\","
            + "\(e.isConfirmed),"
            + "\(String(format: "%.4f", e.confidence))"
        )
    }
    let content = lines.joined(separator: "\n") + "\n"
    try content.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
}

// MARK: - Chunk size parsing

func parseChunkSize(_ s: String) -> StreamingChunkSize? {
    switch s {
    case "160": return .ms160
    case "320": return .ms320
    case "1280": return .ms1280
    default: return nil
    }
}

// MARK: - CLIRunner

struct CLIRunner {
    static func run(args: [String]) async -> Int32 {
        let bootstrapOnly = args.contains("--bootstrap-only")

        // Parse --chunk-size flag (default: 160)
        var chunkSizeStr = "160"
        var i = 1
        while i < args.count {
            if args[i] == "--chunk-size", i + 1 < args.count {
                chunkSizeStr = args[i + 1]
                i += 2
            } else {
                i += 1
            }
        }
        guard let chunkSize = parseChunkSize(chunkSizeStr) else {
            fputs("FATAL: unknown --chunk-size value: \(chunkSizeStr). Use 160, 320, or 1280.\n", stderr)
            return 1
        }

        let bootstrapPath = resolveResultsPath("bootstrap_\(chunkSizeStr)ms.json")

        fputs("INFO: loading Parakeet EOU 120M model (\(chunkSizeStr)ms chunks)...\n", stderr)
        let rssBeforeLoad = currentRSSMB()
        let loadStart = Date()

        let manager: StreamingEouAsrManager
        do {
            manager = try await loadEouManager(chunkSize: chunkSize) { progress in
                fputs("INFO: model progress: \(progress)\n", stderr)
            }
        } catch {
            fputs("FATAL: model load failed: \(error)\n", stderr)
            writeBootstrap(BootstrapResult(
                modelLoadSuccess: false,
                loadDurationMs: Date().timeIntervalSince(loadStart) * 1_000,
                peakRSSMB: currentRSSMB(),
                errorDescription: String(describing: error)
            ), to: bootstrapPath)
            return 1
        }

        let loadDurationMs = Date().timeIntervalSince(loadStart) * 1_000
        let rssAfterLoad = currentRSSMB()
        fputs(
            "INFO: model loaded in \(Int(loadDurationMs))ms — "
            + "RSS \(String(format: "%.1f", rssAfterLoad))MB "
            + "(before-load: \(String(format: "%.1f", rssBeforeLoad))MB)\n",
            stderr
        )

        writeBootstrap(BootstrapResult(
            modelLoadSuccess: true,
            loadDurationMs: loadDurationMs,
            peakRSSMB: rssAfterLoad,
            errorDescription: nil
        ), to: bootstrapPath)

        if bootstrapOnly {
            fputs("INFO: bootstrap-only mode, exiting.\n", stderr)
            return 0
        }

        // Parse remaining args: <input.caf> [--output <output.csv>]
        var inputPath: String?
        var outputPath: String?
        i = 1
        while i < args.count {
            if args[i] == "--output", i + 1 < args.count {
                outputPath = args[i + 1]
                i += 2
            } else if args[i] == "--chunk-size", i + 1 < args.count {
                i += 2
            } else if args[i] == "--bootstrap-only" {
                i += 1
            } else if !args[i].hasPrefix("--") {
                inputPath = args[i]
                i += 1
            } else {
                i += 1
            }
        }

        guard let cafPath = inputPath else {
            fputs(
                "Usage: Spike17_1_5CLI <input.caf> [--output <output.csv>] [--chunk-size 160|320|1280]\n"
                + "       Spike17_1_5CLI --bootstrap-only [--chunk-size 160|320|1280]\n",
                stderr
            )
            return 1
        }

        guard FileManager.default.fileExists(atPath: cafPath) else {
            fputs("FATAL: file not found: \(cafPath)\n", stderr)
            return 1
        }

        let cafURL = URL(fileURLWithPath: cafPath)
        let stem = cafURL.deletingPathExtension().lastPathComponent
        let csvPath = outputPath ?? resolveResultsPath("\(stem)_\(chunkSizeStr)ms.csv")

        fputs("INFO: processing \(cafURL.lastPathComponent) with \(chunkSizeStr)ms chunks...\n", stderr)

        let events: [TokenEvent]
        do {
            events = try await processAudioFile(url: cafURL, manager: manager)
        } catch {
            fputs("FATAL: processing failed: \(error)\n", stderr)
            return 1
        }

        let rssAfterProcess = currentRSSMB()
        fputs(
            "INFO: done — \(events.count) updates, "
            + "peak RSS \(String(format: "%.1f", rssAfterProcess))MB\n",
            stderr
        )

        writeBootstrap(BootstrapResult(
            modelLoadSuccess: true,
            loadDurationMs: loadDurationMs,
            peakRSSMB: max(rssAfterLoad, rssAfterProcess),
            errorDescription: nil
        ), to: bootstrapPath)

        do {
            try writeCSV(events, to: csvPath)
            fputs("INFO: wrote \(csvPath)\n", stderr)
        } catch {
            fputs("ERROR: CSV write failed: \(error)\n", stderr)
            return 1
        }

        return 0
    }

    // Resolves a path under the spike's results/ directory.
    private static func resolveResultsPath(_ filename: String) -> String {
        let cwd = FileManager.default.currentDirectoryPath
        let resultsInCWD = (cwd as NSString).appendingPathComponent("results/\(filename)")
        if FileManager.default.fileExists(
            atPath: (cwd as NSString).appendingPathComponent("Package.swift")
        ) {
            return resultsInCWD
        }
        var url = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path
            ) {
                return url.appendingPathComponent("results/\(filename)").path
            }
            url = url.deletingLastPathComponent()
        }
        return resultsInCWD
    }
}
