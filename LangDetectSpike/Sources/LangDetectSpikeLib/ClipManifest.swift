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
        fatalError("Not implemented — red phase stub")
    }
}

public struct ClipManifest: Codable, Sendable {
    public let clips: [ClipEntry]

    public init(clips: [ClipEntry]) {
        fatalError("Not implemented — red phase stub")
    }

    public static func load(from url: URL) throws -> ClipManifest {
        fatalError("Not implemented — red phase stub")
    }

    public func clips(forLanguage language: String) -> [ClipEntry] {
        fatalError("Not implemented — red phase stub")
    }
}
