// Spike17_1Eval: evaluates per-fixture CSV outputs against the 12 budget criteria.
//
// Usage:
//   swift run Spike17_1Eval clip <fixture_name> --csv <path.csv>
//       Evaluates one clip; writes results/<fixture>.json
//
//   swift run Spike17_1Eval summarize --results-dir <path> --bootstrap <path>
//       Aggregates all clip JSONs; writes results/summary.json
import Foundation

// MARK: - Entry point

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: Spike17_1Eval clip <name> --csv <path>\n"
        + "       Spike17_1Eval summarize --results-dir <dir> --bootstrap <path>\n", stderr)
    exit(1)
}

let subcommand = args[1]

switch subcommand {
case "clip":
    runClip(args: args)
case "summarize":
    runSummarize(args: args)
default:
    fputs("Unknown subcommand: \(subcommand)\n", stderr)
    exit(1)
}

// MARK: - clip subcommand

func runClip(args: [String]) {
    // Parse: clip <name> --csv <path> [--manifest <path>]
    var fixtureName: String?
    var csvPath: String?
    var i = 2
    while i < args.count {
        switch args[i] {
        case "--csv":
            if i + 1 < args.count { csvPath = args[i + 1]; i += 2 } else { i += 1 }
        default:
            if !args[i].hasPrefix("--"), fixtureName == nil {
                fixtureName = args[i]; i += 1
            } else { i += 1 }
        }
    }

    guard let name = fixtureName, let csv = csvPath else {
        fputs("clip requires: <name> --csv <path>\n", stderr)
        exit(1)
    }

    let rows: [CSVRow]
    do {
        rows = try parseCSV(at: csv)
    } catch {
        fputs("ERROR: cannot parse CSV at \(csv): \(error)\n", stderr)
        exit(1)
    }

    let result = buildClipResult(fixture: name, rows: rows)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let outPath = (csv as NSString).deletingLastPathComponent + "/\(name).json"
    if let data = try? encoder.encode(result) {
        try? data.write(to: URL(fileURLWithPath: outPath))
        fputs("INFO: wrote \(outPath)\n", stderr)
    }
}

// MARK: - summarize subcommand

func runSummarize(args: [String]) {
    var resultsDir: String?
    var bootstrapPath: String?
    var manifestPath: String?  // reserved for future manifest-based C8 override
    var i = 2
    while i < args.count {
        switch args[i] {
        case "--results-dir":
            if i + 1 < args.count { resultsDir = args[i + 1]; i += 2 } else { i += 1 }
        case "--bootstrap":
            if i + 1 < args.count { bootstrapPath = args[i + 1]; i += 2 } else { i += 1 }
        case "--manifest":
            if i + 1 < args.count { manifestPath = args[i + 1]; i += 2 } else { i += 1 }
        default:
            i += 1
        }
    }

    guard let dir = resultsDir, let bPath = bootstrapPath else {
        fputs("summarize requires: --results-dir <dir> --bootstrap <path>\n", stderr)
        exit(1)
    }

    // Load bootstrap
    let bootstrap: BootstrapResult
    do {
        bootstrap = try parseBootstrap(at: bPath)
    } catch {
        fputs("ERROR: cannot parse bootstrap.json at \(bPath): \(error)\n", stderr)
        exit(1)
    }

    // Load all per-fixture CSVs from results dir
    let allFixtures = [
        "alternating_pods", "alternating_mac",
        "cafe_noise_pods", "cafe_noise_mac",
        "distractors_pods", "distractors_mac",
        "quiet_speech_pods", "quiet_speech_mac",
        "silence_only_pods", "silence_only_mac",
        "real_world_test",
    ]

    var allRows: [String: [CSVRow]] = [:]
    var clips: [ClipResult] = []

    for fixture in allFixtures {
        let csvPath = "\(dir)/\(fixture).csv"
        guard FileManager.default.fileExists(atPath: csvPath) else {
            fputs("WARN: no CSV for \(fixture), skipping\n", stderr)
            continue
        }
        do {
            let rows = try parseCSV(at: csvPath)
            allRows[fixture] = rows
            clips.append(buildClipResult(fixture: fixture, rows: rows))
        } catch {
            fputs("WARN: cannot parse \(csvPath): \(error)\n", stderr)
        }
    }

    let evaluator = CriteriaEvaluator(bootstrap: bootstrap, clips: clips, allRows: allRows)
    let criteria = evaluator.evaluate()
    let summary = buildSummary(
        bootstrap: bootstrap,
        clips: clips,
        allRows: allRows,
        criteria: criteria
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let summaryPath = "\(dir)/summary.json"
    if let data = try? encoder.encode(summary) {
        try? data.write(to: URL(fileURLWithPath: summaryPath))
    }

    print("verdict: \(summary.verdict)")
    for reason in summary.verdictReasons {
        print("  \(reason)")
    }
    fputs("INFO: wrote \(summaryPath)\n", stderr)
}

// MARK: - ClipResult builder

func buildClipResult(fixture: String, rows: [CSVRow]) -> ClipResult {
    let parts = fixture.split(separator: "_", maxSplits: 10).map(String.init)
    let mic: String
    let clip: String
    if parts.last == "pods" || parts.last == "mac" || parts.last == "test" {
        mic = parts.last!
        clip = parts.dropLast().joined(separator: "_")
    } else {
        mic = "unknown"
        clip = fixture
    }

    let firstUpdate = rows.first
    let confirmedRows = rows.filter { $0.isConfirmed }

    // Estimate audio duration: for 30s fixtures, last emission should be near 30000ms.
    // We use last emission + 500ms as a conservative bound.
    let audioDurationMs = (rows.last?.emissionMs ?? 0) + 500.0

    // Streaming: first update before audio end (using 28s threshold — last 2s grace).
    let firstUpdateBeforeAudioEnd: Bool
    if let first = firstUpdate {
        firstUpdateBeforeAudioEnd = first.emissionMs < max(audioDurationMs - 2_000, 1_000)
    } else {
        firstUpdateBeforeAudioEnd = false
    }

    // Inter-update gaps across ALL updates (confirmed + unconfirmed).
    // StreamingEou emits isConfirmed=true only once per clip (at finish()), so
    // confirmed-only gaps would yield one data point per clip — not meaningful.
    // Using all gaps reflects the actual widget refresh cadence.
    var confirmedGaps: [Double] = []
    if let firstUpdate = rows.first {
        confirmedGaps.append(firstUpdate.emissionMs)
    }
    for i in rows.indices.dropFirst() {
        confirmedGaps.append(rows[i].gapFromPreviousMs)
    }

    let sampleTexts = rows.prefix(3).map { $0.text }

    return ClipResult(
        fixture: fixture,
        clip: clip,
        mic: mic,
        totalUpdateCount: rows.count,
        confirmedUpdateCount: confirmedRows.count,
        firstUpdateEmissionMs: firstUpdate?.emissionMs,
        firstConfirmedEmissionMs: confirmedRows.first?.emissionMs,
        audioDurationMs: audioDurationMs,
        firstUpdateBeforeAudioEnd: firstUpdateBeforeAudioEnd,
        confirmedUpdateGapsMs: confirmedGaps,
        sampleTexts: sampleTexts
    )
}
