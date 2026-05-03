import Foundation

public struct ClipEntry: Codable, Sendable, Equatable {
    public let filename: String
    public let language: String
    public let description: String
    public let approximateWPM: Int?

    enum CodingKeys: String, CodingKey {
        case filename
        case language
        case description
        case approximateWPM = "approximate_wpm"
    }

    public init(
        filename: String,
        language: String,
        description: String,
        approximateWPM: Int? = nil
    ) {
        self.filename = filename
        self.language = language
        self.description = description
        self.approximateWPM = approximateWPM
    }
}

public struct ClipManifest: Codable, Sendable {
    public let clips: [ClipEntry]

    public init(clips: [ClipEntry]) {
        self.clips = clips
    }

    public static func load(from url: URL) throws -> ClipManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ClipManifest.self, from: data)
    }

    public func clips(forLanguage language: String) -> [ClipEntry] {
        clips.filter { $0.language == language }
    }
}
