import Foundation

// ---- Argument parsing ----------------------------------------------------------

func flagValue(_ flag: String, args: [String]) -> String? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

// ---- CSV parsing ---------------------------------------------------------------

func parseCSV(url: URL) -> [TokenRow] {
    guard let content = try? String(contentsOf: url) else { return [] }
    var rows: [TokenRow] = []
    let lines = content.components(separatedBy: "\n").dropFirst()  // skip header
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        // CSV columns: update_index,emission_ms,gap_from_previous_ms,text,is_confirmed,confidence
        // text may contain commas and is quoted
        if let row = parseCSVRow(trimmed) { rows.append(row) }
    }
    return rows
}

private func parseCSVRow(_ line: String) -> TokenRow? {
    // Split on first 3 commas (fixed fields), then parse quoted text + trailing fields
    var parts: [String] = []
    var cur = ""
    var inQuotes = false
    for ch in line {
        if ch == "\"" {
            inQuotes.toggle()
        } else if ch == "," && !inQuotes {
            parts.append(cur)
            cur = ""
        } else {
            cur.append(ch)
        }
    }
    parts.append(cur)
    guard parts.count >= 6 else { return nil }
    guard let idx  = Int(parts[0]),
          let eMs  = Double(parts[1]),
          let gMs  = Double(parts[2]),
          let conf = Float(parts[5]) else { return nil }
    let isConf = parts[4] == "1" || parts[4].lowercased() == "true"
    return TokenRow(updateIndex: idx, emissionMs: eMs, gapFromPreviousMs: gMs,
                    text: parts[3], isConfirmed: isConf, confidence: conf)
}

// ---- Manifest parsing ----------------------------------------------------------

func parseManifest(url: URL) -> [ClipKey: [ManifestEvent]] {
    guard let content = try? String(contentsOf: url) else { return [:] }
    var result: [ClipKey: [ManifestEvent]] = [:]
    let lines = content.components(separatedBy: "\n").dropFirst()
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        let parts = trimmed.split(separator: ",", maxSplits: 4).map(String.init)
        guard parts.count >= 4 else { continue }
        let clip = parts[0]; let mic = parts[1]
        let etype = parts[2]
        let eSecStr = parts[3].trimmingCharacters(in: .whitespaces)
        guard let eSec = Double(eSecStr) else { continue }
        let key = ClipKey(clip: clip, mic: mic)
        let ev = ManifestEvent(clip: clip, mic: mic, eventType: etype, eventSeconds: eSec)
        result[key, default: []].append(ev)
    }
    return result
}

// ---- JSON helpers --------------------------------------------------------------

func loadJSON(url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
}

// ---- Output -------------------------------------------------------------------

struct SummaryOutput: Codable {
    var model: String
    var criteria: [CriterionResult]
    var overallVerdict: String
    var noSkippingTriggered: Bool
}

func printTable(_ results: [CriterionResult]) {
    func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
    print("\(pad("ID",4))  \(pad("Name",36))  \(pad("Verdict",10))  \(pad("Measured",20))  Budget")
    print(String(repeating: "-", count: 100))
    for r in results {
        print("\(pad(r.id,4))  \(pad(r.name,36))  \(pad(r.disposition.rawValue,10))  \(pad(r.measured,20))  \(r.budget)")
    }
}

// ---- main ----------------------------------------------------------------------

let args = CommandLine.arguments
let model       = flagValue("--model",           args: args) ?? "small"
let criteriaStr = flagValue("--criteria",        args: args) ?? "all"
let manifestArg = flagValue("--manifest",        args: args) ?? "recordings/manifest.csv"
let resultsDir  = flagValue("--results-dir",     args: args) ?? "results"
let smokeFile   = flagValue("--smoke-baseline",  args: args) ?? "results/SMOKE_BASELINE.json"
let bootstrapFile = "results/bootstrap_\(model).json"
let outputFile  = flagValue("--output",          args: args) ?? "results/GATE2_summary_\(model).json"

// Load bootstrap
let bootstrapJSON = loadJSON(url: URL(fileURLWithPath: bootstrapFile))
if bootstrapJSON.isEmpty {
    print("[eval] WARNING: bootstrap file not found: \(bootstrapFile)")
}

// Load smoke baseline
let smokeJSON = loadJSON(url: URL(fileURLWithPath: smokeFile))

// Load manifest
let manifestURL = URL(fileURLWithPath: manifestArg)
let manifest = parseManifest(url: manifestURL)

// Discover fixture CSVs in results dir
let fixtures = [
    "alternating_pods", "alternating_mac",
    "quiet_speech_pods", "quiet_speech_mac",
    "cafe_noise_pods", "cafe_noise_mac",
    "silence_only_pods", "silence_only_mac",
    "distractors_pods", "distractors_mac",
]

var fixtureRows: [String: [TokenRow]] = [:]
for fixture in fixtures {
    let csvName = "\(fixture)_\(model).csv"
    let csvURL = URL(fileURLWithPath: "\(resultsDir)/\(csvName)")
    if FileManager.default.fileExists(atPath: csvURL.path) {
        fixtureRows[fixture] = parseCSV(url: csvURL)
    } else {
        print("[eval] WARNING: missing CSV for \(fixture) — \(csvURL.path)")
    }
}

// Score all criteria
let scorer = CriteriaScorer(
    bootstrapJSON: bootstrapJSON,
    smokeBaseline: smokeJSON,
    fixtureRows: fixtureRows,
    manifest: manifest
)

let results: [CriterionResult]
if criteriaStr == "all" {
    results = scorer.scoreAll()
} else {
    let ids = criteriaStr.uppercased().split(separator: ",").map(String.init)
    let allResults = scorer.scoreAll()
    results = allResults.filter { ids.contains($0.id) }
}

printTable(results)

// Overall verdict
let fails = results.filter { $0.disposition == .fail }
let noSkipping = results.first(where: { $0.id == "C4" })?.notes.contains("10×") ?? false
let verdict: String
if noSkipping { verdict = "GATE_FAIL_NO_SKIPPING" }
else if fails.isEmpty { verdict = "PASS" }
else { verdict = "FAIL" }

print("\nOverall verdict: \(verdict)")
if !fails.isEmpty {
    print("Failed criteria: \(fails.map(\.id).joined(separator: ", "))")
}

// Write JSON output
let summary = SummaryOutput(
    model: model,
    criteria: results,
    overallVerdict: verdict,
    noSkippingTriggered: noSkipping
)
if let data = try? JSONEncoder().encode(summary) {
    try? FileManager.default.createDirectory(
        at: URL(fileURLWithPath: outputFile).deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try? data.write(to: URL(fileURLWithPath: outputFile))
    print("Summary written to \(outputFile)")
}
