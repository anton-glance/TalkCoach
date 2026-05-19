import Foundation

// MARK: - Argument dispatch

let args = CommandLine.arguments.dropFirst()

if args.contains("--summarize") {
    runSummarize(args: Array(args))
} else if args.contains("--clip") {
    runPerClip(args: Array(args))
} else {
    fprintErr("Usage:")
    fprintErr("  Spike16Eval --clip <name> --csv <path> --manifest <path> --output <path>")
    fprintErr("  Spike16Eval --summarize --results-dir <path>")
    exit(1)
}

// MARK: - Per-clip mode

func runPerClip(args: [String]) {
    var clip = ""; var csvPath = ""; var manifestPath = ""; var outputPath = ""
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--clip":      i += 1; if i < args.count { clip = args[i] }
        case "--csv":       i += 1; if i < args.count { csvPath = args[i] }
        case "--manifest":  i += 1; if i < args.count { manifestPath = args[i] }
        case "--output":    i += 1; if i < args.count { outputPath = args[i] }
        default: break
        }
        i += 1
    }
    guard !clip.isEmpty, !csvPath.isEmpty, !manifestPath.isEmpty, !outputPath.isEmpty else {
        fprintErr("ERROR: --clip, --csv, --manifest, --output are all required")
        exit(1)
    }

    // Derive base clip name and mic from e.g. "alternating_pods" → ("alternating", "pods")
    let parts = clip.components(separatedBy: "_")
    guard parts.count >= 2 else {
        fprintErr("ERROR: clip name must be <base>_<mic>, got '\(clip)'")
        exit(1)
    }
    let mic = parts.last!
    let baseName = parts.dropLast().joined(separator: "_")

    let rows = parseCSV(path: csvPath)
    guard !rows.isEmpty else {
        fprintErr("ERROR: CSV at '\(csvPath)' has no rows")
        exit(1)
    }

    let allEvents = parseManifest(path: manifestPath)
    let clipEvents = allEvents.filter { $0.clip == baseName && $0.mic == mic }

    let clipDurationMS = rows.last?.timestampMS ?? 0
    let transitions = buildTransitions(rows: rows)
    let (fallbackUsed, effectiveThreshold) = extractCalibrationInfo(rows: rows)

    // Build speech, silence, and distractor intervals from events
    var speechIntervals: [(start: Int, end: Int)] = []
    var silenceIntervals: [(start: Int, end: Int)] = []
    var distractorSpecs: [(type: String, start: Int, end: Int)] = []
    var distractorSilenceInterval: (start: Int, end: Int)? = nil

    let isNoEvent = clipEvents.first?.eventType == "no_event"

    if isNoEvent {
        // silence_only: entire clip is silence
        silenceIntervals.append((0, clipDurationMS))
    } else {
        // Build speech intervals from speech_onset / speech_end pairs
        var currentOnset: Int? = nil
        var silenceStart: Int? = nil
        var silenceEnd: Int? = nil

        let sortedEvents = clipEvents.sorted { $0.eventSeconds < $1.eventSeconds }

        for event in sortedEvents {
            let eMS = Int(event.eventSeconds * 1000.0)
            switch event.eventType {
            case "speech_onset":
                currentOnset = eMS
            case "speech_end":
                if let onset = currentOnset {
                    speechIntervals.append((onset, eMS))
                    currentOnset = nil
                }
                silenceIntervals.append((eMS, min(eMS + 99999, clipDurationMS)))  // will be trimmed by next onset
            case "typing_start":
                distractorSpecs.append(("typing", eMS, eMS))  // end TBD
            case "typing_end":
                if let idx = distractorSpecs.indices.last(where: { distractorSpecs[$0].type == "typing" && distractorSpecs[$0].end == distractorSpecs[$0].start }) {
                    distractorSpecs[idx] = ("typing", distractorSpecs[idx].start, eMS)
                }
            case "door_slam":
                distractorSpecs.append(("door_slam", eMS, eMS))
            case "door_slam_end":
                if let idx = distractorSpecs.indices.last(where: { distractorSpecs[$0].type == "door_slam" && distractorSpecs[$0].end == distractorSpecs[$0].start }) {
                    distractorSpecs[idx] = ("door_slam", distractorSpecs[idx].start, eMS)
                }
            case "notification_start":
                distractorSpecs.append(("notification", eMS, eMS))
            case "notification_end":
                if let idx = distractorSpecs.indices.last(where: { distractorSpecs[$0].type == "notification" && distractorSpecs[$0].end == distractorSpecs[$0].start }) {
                    distractorSpecs[idx] = ("notification", distractorSpecs[idx].start, eMS)
                }
            case "silence_start":
                silenceStart = eMS
            case "silence_end":
                silenceEnd = eMS
            default: break
            }
        }
        // If there's an unclosed speech interval (speech continues to end of clip)
        if let onset = currentOnset {
            speechIntervals.append((onset, clipDurationMS))
        }

        // For distractors: speech continues through distractor events.
        // If the clip has a deliberate silence interval, the speech interval before it
        // was already captured by the speech_end/silence_start events (but distractors
        // have no speech_end events — only silence_start). Handle this:
        if let sStart = silenceStart, let sEnd = silenceEnd {
            distractorSilenceInterval = (sStart, sEnd)
            // speech from onset to silence_start (if no speech_end was emitted)
            if speechIntervals.isEmpty, let onset = clipEvents.first(where: { $0.eventType == "speech_onset" }).map({ Int($0.eventSeconds * 1000.0) }) {
                speechIntervals.append((onset, sStart))
                speechIntervals.append((sEnd, clipDurationMS))
            }
            // Add silence interval for the deliberate silence window
            silenceIntervals.append((sStart, sEnd))
        }

        // Fix up silence intervals that were opened with 99999 end — close them at next onset or clip end
        silenceIntervals = silenceIntervals.compactMap { interval in
            let end = min(interval.end, clipDurationMS)
            guard end > interval.start else { return nil }
            return (interval.start, end)
        }
        // For alternating clips, silence intervals between speech windows:
        // They were set to (speech_end, 99999) — trim by next speechInterval start
        var fixedSilences: [(start: Int, end: Int)] = []
        for si in silenceIntervals {
            // Find the next speech onset after this silence start
            let nextOnset = speechIntervals.first { $0.start >= si.start }?.start ?? clipDurationMS
            let actualEnd = min(si.end, nextOnset)
            if actualEnd > si.start {
                fixedSilences.append((si.start, actualEnd))
            }
        }
        silenceIntervals = fixedSilences
    }

    // Compute onset latencies
    let onsetSeconds = clipEvents.filter { $0.eventType == "speech_onset" }.map { $0.eventSeconds }
    let onsetLatencies = computeOnsetLatencies(eventSeconds: onsetSeconds, transitions: transitions)
    let sortedOnset = onsetLatencies.sorted()

    // Compute end latencies
    let endSeconds = clipEvents.filter { $0.eventType == "speech_end" }.map { $0.eventSeconds }
    let endLatencies = computeEndLatencies(eventSeconds: endSeconds, transitions: transitions,
                                           clipDurationMS: clipDurationMS)
    let sortedEnd = endLatencies.sorted()

    // Compute speech FN rates
    let speechFNResults = speechIntervals.map { interval in
        computeFalseNegativeRate(rows: rows, startMS: interval.start, endMS: interval.end)
    }

    // Compute silence FP durations
    let silenceFPResults = silenceIntervals.map { interval in
        (start_ms: interval.start, end_ms: interval.end,
         fp_ms: computeFalsePositiveDuration(rows: rows, startMS: interval.start, endMS: interval.end))
    }

    // Compute distractor intervals
    let distractorResults = distractorSpecs.filter { $0.start < $0.end }.map { spec in
        computeDistractorInterval(rows: rows, transitions: transitions,
                                  eventType: spec.type, startMS: spec.start, endMS: spec.end)
    }

    // Distractor deliberate-silence false positive
    let distSilenceFP = distractorSilenceInterval.map { interval in
        computeFalsePositiveDuration(rows: rows, startMS: interval.start, endMS: interval.end)
    } ?? 0

    let result = ClipResult(
        clip: clip,
        mic: mic,
        calibrationFallbackUsed: fallbackUsed,
        effectiveThresholdDB_at_calibration: effectiveThreshold,
        onsetLatencies_ms: onsetLatencies,
        onsetLatency_median_ms: median(sortedOnset),
        onsetLatency_p95_ms: percentile(sortedOnset, 0.95),
        onsetLatency_max_ms: sortedOnset.max() ?? 0,
        endLatencies_ms: endLatencies,
        endLatency_median_ms: median(sortedEnd),
        endLatency_p95_ms: percentile(sortedEnd, 0.95),
        endLatency_max_ms: sortedEnd.max() ?? 0,
        speechIntervals: speechFNResults.map {
            SpeechInterval(start_ms: $0.start_ms, end_ms: $0.end_ms,
                           falseNegativeRate_pct: $0.falseNegativeRate_pct,
                           falseNegativeDuration_ms: $0.falseNegativeDuration_ms)
        },
        silenceIntervals: silenceFPResults.map {
            SilenceInterval(start_ms: $0.start_ms, end_ms: $0.end_ms,
                            falsePositiveDuration_ms: $0.fp_ms)
        },
        distractorIntervals: distractorResults.map {
            DistractorInterval(type: $0.eventType, start_ms: $0.start_ms, end_ms: $0.end_ms,
                               incorrectStateDuration_ms: $0.incorrectStateDuration_ms,
                               incorrectStateRate_pct: $0.incorrectStateRate_pct,
                               latencyToCorrect_ms: $0.latencyToCorrect_ms)
        },
        distractorSilenceFalsePositive_ms: distSilenceFP
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(result) else {
        fprintErr("ERROR: JSON encoding failed for clip \(clip)")
        exit(1)
    }
    do {
        try data.write(to: URL(fileURLWithPath: outputPath))
        fprintErr("OK: wrote \(outputPath)")
    } catch {
        fprintErr("ERROR: cannot write to '\(outputPath)': \(error)")
        exit(1)
    }
}

// MARK: - Summarize mode

func runSummarize(args: [String]) {
    var resultsDir = ""
    var i = 0
    while i < args.count {
        if args[i] == "--results-dir" { i += 1; if i < args.count { resultsDir = args[i] } }
        i += 1
    }
    guard !resultsDir.isEmpty else {
        fprintErr("ERROR: --results-dir is required for --summarize")
        exit(1)
    }

    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: resultsDir) else {
        fprintErr("ERROR: cannot list directory '\(resultsDir)'")
        exit(1)
    }

    let jsonFiles = files.filter { $0.hasSuffix(".json") && $0 != "summary.json" && $0 != "parameter_sweep.csv" }.sorted()
    var clips: [ClipResult] = []
    let decoder = JSONDecoder()
    for file in jsonFiles {
        let path = (resultsDir as NSString).appendingPathComponent(file)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let clip = try? decoder.decode(ClipResult.self, from: data) else {
            fprintErr("WARNING: cannot decode '\(path)' — skipping")
            continue
        }
        clips.append(clip)
    }

    guard clips.count == 10 else {
        fprintErr("ERROR: expected 10 clip JSON files, found \(clips.count) in '\(resultsDir)'")
        exit(1)
    }

    let summary = buildSummary(clips: clips)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(summary) else {
        fprintErr("ERROR: JSON encoding failed for summary")
        exit(1)
    }
    let summaryPath = (resultsDir as NSString).appendingPathComponent("summary.json")
    do {
        try data.write(to: URL(fileURLWithPath: summaryPath))
        fprintErr("OK: wrote \(summaryPath)")
    } catch {
        fprintErr("ERROR: cannot write summary to '\(summaryPath)': \(error)")
        exit(1)
    }
}
