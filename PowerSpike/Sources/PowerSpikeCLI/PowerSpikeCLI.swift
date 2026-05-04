@preconcurrency import AVFoundation
import Foundation
import PowerSpikeLib
import Speech
import os

private let logger = Logger(
    subsystem: "com.talkcoach.app",
    category: "power-spike"
)

private final class ConfigChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count: Int = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        _count += 1
        let v = _count
        lock.unlock()
        return v
    }

    var value: Int {
        lock.lock()
        let v = _count
        lock.unlock()
        return v
    }
}

@main
struct PowerSpikeCLI {
    static func main() async throws {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--help") {
            printUsage()
            return
        }

        let isolatedDuration = parseDouble(
            args: args, flag: "--isolated-duration", defaultValue: 900
        )
        let totalDuration = parseDouble(
            args: args, flag: "--total-duration", defaultValue: 3600
        )
        let sampleInterval = parseDouble(
            args: args, flag: "--sample-interval", defaultValue: 10.0
        )
        let outputPath = parseString(
            args: args,
            flag: "--output",
            defaultValue: "results/power_baseline.csv"
        )

        fputs("PowerSpike — Apple SpeechAnalyzer Power Baseline\n", stderr)
        fputs(
            "Isolated: \(Int(isolatedDuration))s, Total: \(Int(totalDuration))s\n",
            stderr
        )
        fputs(
            "Sample interval: \(sampleInterval)s, Output: \(outputPath)\n",
            stderr
        )

        await LiveTranscriptionRunner.checkAssets()

        let rmsAccumulator = RMSAccumulator()
        let bufferRelay = BufferRelay()
        nonisolated(unsafe) let engine = AVAudioEngine()
        nonisolated(unsafe) let inputNode = engine.inputNode

        do {
            try inputNode.setVoiceProcessingEnabled(false)
        } catch {
            fputs(
                "WARNING: setVoiceProcessingEnabled(false) threw: \(error)\n",
                stderr
            )
        }

        let hwFormat = inputNode.inputFormat(forBus: 0)
        fputs(
            "Input format: \(hwFormat.sampleRate) Hz, \(hwFormat.channelCount) ch\n",
            stderr
        )

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: nil,
            block: makeTapHandler(
                rmsAccumulator: rmsAccumulator,
                bufferRelay: bufferRelay
            )
        )

        let configCounter = ConfigChangeCounter()
        let configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { _ in
            let count = configCounter.increment()
            let newFormat = inputNode.inputFormat(forBus: 0)
            fputs(
                "[CONFIG CHANGE #\(count)] \(newFormat.sampleRate) Hz, \(newFormat.channelCount) ch\n",
                stderr
            )
            logger.warning(
                "Config change detected, count=\(count)"
            )

            do {
                inputNode.removeTap(onBus: 0)
                engine.prepare()
                try engine.start()
                inputNode.installTap(
                    onBus: 0,
                    bufferSize: 4096,
                    format: nil,
                    block: makeTapHandler(
                        rmsAccumulator: rmsAccumulator,
                        bufferRelay: bufferRelay
                    )
                )
                fputs("[CONFIG CHANGE] Engine recovered.\n", stderr)
            } catch {
                fputs(
                    "[CONFIG CHANGE] Recovery FAILED: \(error)\n",
                    stderr
                )
            }
        }

        engine.prepare()
        try engine.start()
        fputs("Engine running.\n", stderr)

        let runner = LiveTranscriptionRunner()
        let transcriptionTask = Task {
            do {
                try await runner.startTranscribing(
                    bufferRelay: bufferRelay,
                    sourceFormat: hwFormat
                )
            } catch {
                fputs("Transcription task error: \(error)\n", stderr)
                logger.error("Transcription task error: \(error)")
            }
        }

        let measurement = SelfMeasurement()
        var rows: [MeasurementRow] = []
        var previousSnapshot = CPUSnapshot()

        let startTime = ProcessInfo.processInfo.systemUptime
        var nextSampleTime = startTime + sampleInterval
        let endTime = startTime + totalDuration

        var markerInserted = false

        fputs(
            "\nSampling every \(Int(sampleInterval))s. Marker at \(Int(isolatedDuration))s. End at \(Int(totalDuration))s.\n",
            stderr
        )
        fputs(MeasurementRow.csvHeader + "\n", stderr)

        while ProcessInfo.processInfo.systemUptime < endTime {
            let now = ProcessInfo.processInfo.systemUptime
            let sleepDuration = nextSampleTime - now
            if sleepDuration > 0 {
                try await Task.sleep(for: .seconds(sleepDuration))
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - startTime

            if !markerInserted && elapsed >= isolatedDuration {
                markerInserted = true
                let currentSnapshot = CPUSnapshot()
                let cpu = measurement.cpuPercent(
                    from: previousSnapshot, to: currentSnapshot
                )
                let rss = measurement.rssMB()
                let rms = rmsAccumulator.consumeRMS()
                let thermal = measurement.thermalState()
                let txSnapshot = await runner.snapshot(elapsed: elapsed)

                let markerRow = MeasurementRow(
                    elapsedSeconds: elapsed,
                    cpuUserPercent: cpu.user,
                    cpuSystemPercent: cpu.system,
                    cpuTotalPercent: cpu.user + cpu.system,
                    rssMB: rss,
                    wordsTotal: txSnapshot.wordCount,
                    speakingDurationSeconds: txSnapshot.speakingDuration,
                    avgWPM: txSnapshot.avgWPM,
                    rmsAvg: rms,
                    thermalState: thermal,
                    marker: "SCENARIO_BOUNDARY"
                )
                rows.append(markerRow)
                fputs(markerRow.csvLine + "\n", stderr)
                previousSnapshot = currentSnapshot
                fputs(
                    "\n>>> SCENARIO BOUNDARY at \(String(format: "%.0f", elapsed))s <<<\n\n",
                    stderr
                )
                nextSampleTime += sampleInterval
                continue
            }

            let currentSnapshot = CPUSnapshot()
            let cpu = measurement.cpuPercent(
                from: previousSnapshot, to: currentSnapshot
            )
            let rss = measurement.rssMB()
            let rms = rmsAccumulator.consumeRMS()
            let thermal = measurement.thermalState()
            let txSnapshot = await runner.snapshot(elapsed: elapsed)

            let row = MeasurementRow(
                elapsedSeconds: elapsed,
                cpuUserPercent: cpu.user,
                cpuSystemPercent: cpu.system,
                cpuTotalPercent: cpu.user + cpu.system,
                rssMB: rss,
                wordsTotal: txSnapshot.wordCount,
                speakingDurationSeconds: txSnapshot.speakingDuration,
                avgWPM: txSnapshot.avgWPM,
                rmsAvg: rms,
                thermalState: thermal,
                marker: ""
            )
            rows.append(row)
            fputs(row.csvLine + "\n", stderr)

            previousSnapshot = currentSnapshot
            nextSampleTime += sampleInterval
        }

        transcriptionTask.cancel()
        engine.stop()
        inputNode.removeTap(onBus: 0)
        NotificationCenter.default.removeObserver(configObserver)

        try writeCSV(rows: rows, path: outputPath)

        let finalTx = await runner.snapshot(
            elapsed: ProcessInfo.processInfo.systemUptime - startTime
        )
        printSummary(
            rows: rows,
            totalDuration: totalDuration,
            finalTx: finalTx,
            configChanges: configCounter.value,
            outputPath: outputPath
        )
    }

    private static func printSummary(
        rows: [MeasurementRow],
        totalDuration: Double,
        finalTx: TranscriptionSnapshot,
        configChanges: Int,
        outputPath: String
    ) {
        fputs("\n--- SUMMARY ---\n", stderr)
        fputs(
            "Duration: \(String(format: "%.0f", totalDuration))s\n",
            stderr
        )
        fputs(
            "Total words recognized: \(finalTx.wordCount)\n",
            stderr
        )
        fputs(
            "Speaking duration: \(String(format: "%.1f", finalTx.speakingDuration))s\n",
            stderr
        )
        fputs("Config changes: \(configChanges)\n", stderr)
        fputs("CSV written to: \(outputPath)\n", stderr)

        let dataRows = rows.filter { $0.marker.isEmpty }
        let cpuValues = dataRows.map(\.cpuTotalPercent)
        guard !cpuValues.isEmpty else { return }

        let sorted = cpuValues.sorted()
        let mean = cpuValues.reduce(0, +) / Double(cpuValues.count)
        let p95Index = Int(Double(sorted.count) * 0.95)
        let p95 = sorted[min(p95Index, sorted.count - 1)]
        let maxCPU = sorted.last!
        let maxRSS = dataRows.map(\.rssMB).max() ?? 0
        let headroom = 5.0 - p95

        let classification: String
        if headroom > 2.0 {
            classification = "SAFE"
        } else if headroom >= 1.0 {
            classification = "TIGHT"
        } else {
            classification = "AT_RISK"
        }

        fputs("\n--- QUICK ANALYSIS ---\n", stderr)
        fputs(
            "CPU: mean=\(String(format: "%.2f", mean))%  P95=\(String(format: "%.2f", p95))%  max=\(String(format: "%.2f", maxCPU))%\n",
            stderr
        )
        fputs(
            "RSS: max=\(String(format: "%.1f", maxRSS))MB\n",
            stderr
        )
        fputs(
            "Headroom: \(String(format: "%.2f", headroom))% -> \(classification)\n",
            stderr
        )

        let thermalMax = rows.map(\.thermalState).max() ?? 0
        fputs("Thermal state max: \(thermalMax)\n", stderr)

        if classification == "AT_RISK" {
            fputs(
                "\nAT_RISK: P95 CPU leaves <1% headroom for Phase 4 analyzers. Spike FAILS.\n",
                stderr
            )
        }
    }

    private static func writeCSV(
        rows: [MeasurementRow], path: String
    ) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )

        var csv = MeasurementRow.csvHeader + "\n"
        for row in rows {
            csv += row.csvLine + "\n"
        }
        try csv.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func parseDouble(
        args: [String], flag: String, defaultValue: Double
    ) -> Double {
        guard let index = args.firstIndex(of: flag),
            index + 1 < args.count,
            let value = Double(args[index + 1])
        else {
            return defaultValue
        }
        return value
    }

    private static func parseString(
        args: [String], flag: String, defaultValue: String
    ) -> String {
        guard let index = args.firstIndex(of: flag),
            index + 1 < args.count
        else {
            return defaultValue
        }
        return args[index + 1]
    }

    private static func printUsage() {
        fputs(
            """
            Usage: PowerSpikeCLI [options]

            Options:
              --isolated-duration <seconds>  Duration of isolated phase (default: 900)
              --total-duration <seconds>     Total run duration (default: 3600)
              --sample-interval <seconds>    Measurement interval (default: 10)
              --output <path>                CSV output path (default: results/power_baseline.csv)
              --help                         Show this message

            Runs AVAudioEngine + SpeechAnalyzer on live mic input, measures CPU%,
            RSS, and thermal state every sample-interval seconds. Inserts a
            SCENARIO_BOUNDARY marker at isolated-duration. Writes CSV at exit.

            """,
            stderr
        )
    }
}
