import Foundation

// MARK: - CSV parser

func parseCSV(at path: String) throws -> [CSVRow] {
    let content = try String(contentsOfFile: path, encoding: .utf8)
    var rows: [CSVRow] = []
    let lines = content.components(separatedBy: "\n")

    for (i, line) in lines.enumerated() {
        if i == 0 { continue }  // skip header
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }

        let fields = parseCSVLine(trimmed)
        guard fields.count >= 5 else { continue }

        guard let idx = Int(fields[0]),
              let emissionMs = Double(fields[1]),
              let gapMs = Double(fields[2])
        else { continue }

        // text field may be quoted
        let rawText = fields[3].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let unescaped = rawText.replacingOccurrences(of: "\"\"", with: "\"")
        let isConfirmed = fields[4].trimmingCharacters(in: .whitespaces).lowercased() == "true"
        let confidence = fields.count > 5
            ? Double(fields[5].trimmingCharacters(in: .whitespaces)) ?? -1.0
            : -1.0

        rows.append(CSVRow(
            updateIndex: idx,
            emissionMs: emissionMs,
            gapFromPreviousMs: gapMs,
            text: unescaped,
            isConfirmed: isConfirmed,
            confidence: confidence
        ))
    }
    return rows
}

// Naive CSV field splitter that handles one level of double-quote escaping.
private func parseCSVLine(_ line: String) -> [String] {
    var fields: [String] = []
    var current = ""
    var inQuotes = false
    var chars = line.makeIterator()

    while let c = chars.next() {
        if c == "\"" {
            inQuotes.toggle()
        } else if c == "," && !inQuotes {
            fields.append(current)
            current = ""
        } else {
            current.append(c)
        }
    }
    fields.append(current)
    return fields
}

// MARK: - Manifest parser

func parseManifest(at path: String) throws -> [ManifestEvent] {
    let content = try String(contentsOfFile: path, encoding: .utf8)
    var events: [ManifestEvent] = []
    let lines = content.components(separatedBy: "\n")

    for (i, line) in lines.enumerated() {
        if i == 0 { continue }  // header
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }

        let fields = parseCSVLine(trimmed)
        guard fields.count >= 4 else { continue }

        let clip = fields[0].trimmingCharacters(in: .whitespaces)
        let mic = fields[1].trimmingCharacters(in: .whitespaces)
        let eventType = fields[2].trimmingCharacters(in: .whitespaces)
        let rawSeconds = fields[3].trimmingCharacters(in: .whitespaces)
        let notes = fields.count > 4
            ? fields[4].trimmingCharacters(in: .whitespaces)
            : ""

        let seconds = Double(rawSeconds)  // nil for "nan"

        events.append(ManifestEvent(
            clip: clip, mic: mic, eventType: eventType,
            eventSeconds: seconds, notes: notes
        ))
    }
    return events
}

// MARK: - Bootstrap parser

func parseBootstrap(at path: String) throws -> BootstrapResult {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode(BootstrapResult.self, from: data)
}
