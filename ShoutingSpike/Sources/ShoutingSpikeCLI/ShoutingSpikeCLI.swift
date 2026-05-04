import Foundation
import ShoutingSpikeLib

@main
struct ShoutingSpikeCLI {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.contains("--help") || args.contains("-h") {
            printUsage()
            return
        }

        guard let inputPath = parseInput(args: args) else {
            fputs("Error: no input file specified. Use --help for usage.\n", stderr)
            exit(1)
        }

        guard FileManager.default.fileExists(atPath: inputPath) else {
            fputs("Error: file not found: \(inputPath)\n", stderr)
            exit(1)
        }

        let bufferLength = parseDouble(args: args, flag: "--buffer-length-seconds", default: 5.0)
        let percentile = parseDouble(args: args, flag: "--percentile", default: 10.0)
        let thresholdDB = parseDouble(args: args, flag: "--threshold-db", default: 25.0)
        let minEventDuration = parseDouble(args: args, flag: "--min-event-duration-seconds", default: 0.5)
        let hopMs = parseInt(args: args, flag: "--hop-ms", default: 100)
        let hopSeconds = Double(hopMs) / 1000.0
        let summaryCSVPath = parseString(args: args, flag: "--summary-csv")
        let timeSeriesCSVPath = parseString(args: args, flag: "--time-series-csv")

        let (dBFSSeries, _, durationSeconds) = try RMSExtractor.extract(
            from: inputPath, hopSeconds: hopSeconds
        )

        var anf = AdaptiveNoiseFloor(
            bufferLengthSeconds: bufferLength,
            percentile: percentile,
            thresholdDB: thresholdDB,
            minEventDurationSeconds: minEventDuration,
            hopSeconds: hopSeconds
        )

        var ticks: [Tick] = []
        ticks.reserveCapacity(dBFSSeries.count)
        for (k, sample) in dBFSSeries.enumerated() {
            let tick = anf.process(sample: sample, atTimeSeconds: Double(k) * hopSeconds)
            ticks.append(tick)
        }

        let clipName = URL(fileURLWithPath: inputPath)
            .deletingPathExtension().lastPathComponent
        let summary = anf.summary(clipName: clipName, durationSeconds: durationSeconds)

        if let path = summaryCSVPath {
            try writeSummary(summary, toPath: path)
        } else {
            print(ClipSummary.csvHeader)
            print(summary.csvLine)
        }

        if let tsPath = timeSeriesCSVPath {
            try writeTimeSeries(ticks, toPath: tsPath)
        }
    }

    // MARK: - Output

    private static func writeSummary(_ summary: ClipSummary, toPath path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: path) {
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write((summary.csvLine + "\n").data(using: .utf8)!)
            handle.closeFile()
        } else {
            let content = ClipSummary.csvHeader + "\n" + summary.csvLine + "\n"
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func writeTimeSeries(_ ticks: [Tick], toPath path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var lines = [Tick.csvHeader]
        for tick in ticks {
            lines.append(tick.csvLine)
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Flag parsing

    private static let knownFlags: Set<String> = [
        "--input", "--buffer-length-seconds", "--percentile", "--threshold-db",
        "--min-event-duration-seconds", "--hop-ms", "--summary-csv", "--time-series-csv"
    ]

    private static func parseInput(args: [String]) -> String? {
        if let index = args.firstIndex(of: "--input"), index + 1 < args.count {
            return args[index + 1]
        }
        var skipNext = false
        for arg in args {
            if skipNext { skipNext = false; continue }
            if knownFlags.contains(arg) { skipNext = true; continue }
            if !arg.hasPrefix("--") { return arg }
        }
        return nil
    }

    private static func parseDouble(args: [String], flag: String, default d: Double) -> Double {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count,
              let v = Double(args[i + 1]) else { return d }
        return v
    }

    private static func parseInt(args: [String], flag: String, default d: Int) -> Int {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count,
              let v = Int(args[i + 1]) else { return d }
        return v
    }

    private static func parseString(args: [String], flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func printUsage() {
        let text = """
        Usage: ShoutingSpikeCLI [--input] <audio-file> [options]

        Options:
          --buffer-length-seconds <Double>       Rolling buffer length (default: 5.0)
          --percentile <Double>                  Noise floor percentile (default: 10.0)
          --threshold-db <Double>                Threshold above floor (default: 25.0)
          --min-event-duration-seconds <Double>  Sustain requirement (default: 0.5)
          --hop-ms <Int>                         Hop size in ms (default: 100)
          --summary-csv <path>                   Write summary to file (default: stdout)
          --time-series-csv <path>               Write per-hop time series to file
          --help                                 Show this help
        """
        print(text)
    }
}
