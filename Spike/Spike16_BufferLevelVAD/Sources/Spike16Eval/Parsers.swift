import Foundation

// MARK: - CSV row from Spike16CLI output

struct CSVRow {
    let timestampMS: Int
    let rmsDB: Float
    let noiseFloorDB: Float
    let thresholdDB: Float
    let isVoiceActive: Bool
    let calibrationState: String
}

func parseCSV(path: String) -> [CSVRow] {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        fprintErr("ERROR: cannot read CSV at \(path)")
        return []
    }
    var rows: [CSVRow] = []
    let lines = content.components(separatedBy: "\n")
    for line in lines.dropFirst() {  // skip header
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        let cols = trimmed.components(separatedBy: ",")
        guard cols.count == 6,
              let ts = Int(cols[0]),
              let rms = Float(cols[1]),
              let nf = Float(cols[2]),
              let th = Float(cols[3]) else { continue }
        let active = cols[4] == "true"
        rows.append(CSVRow(timestampMS: ts, rmsDB: rms, noiseFloorDB: nf, thresholdDB: th,
                           isVoiceActive: active, calibrationState: cols[5]))
    }
    return rows
}

// MARK: - Manifest event

struct ManifestEvent {
    let clip: String
    let mic: String
    let eventType: String
    let eventSeconds: Double
    let notes: String
}

func parseManifest(path: String) -> [ManifestEvent] {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        fprintErr("ERROR: cannot read manifest at \(path)")
        return []
    }
    var events: [ManifestEvent] = []
    let lines = content.components(separatedBy: "\n")
    for line in lines.dropFirst() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        let cols = trimmed.components(separatedBy: ",")
        guard cols.count >= 4 else { continue }
        let clip = cols[0].trimmingCharacters(in: .whitespaces)
        let mic = cols[1].trimmingCharacters(in: .whitespaces)
        let eventType = cols[2].trimmingCharacters(in: .whitespaces)
        let secsStr = cols[3].trimmingCharacters(in: .whitespaces)
        let secs = Double(secsStr) ?? Double.nan
        let notes = cols.count > 4 ? cols[4...].joined(separator: ",") : ""
        events.append(ManifestEvent(clip: clip, mic: mic, eventType: eventType,
                                    eventSeconds: secs, notes: notes))
    }
    return events
}

// MARK: - Helpers

func fprintErr(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

func percentile(_ sorted: [Int], _ p: Double) -> Int {
    guard !sorted.isEmpty else { return 0 }
    let idx = Int((Double(sorted.count - 1) * p).rounded(.down))
    return sorted[min(idx, sorted.count - 1)]
}

func median(_ values: [Int]) -> Int {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}
