import Foundation
import Testing
@testable import LangDetectSpikeLib

struct ClipManifestTests {

    @Test func parsesValidManifest() throws {
        let json = """
        {
            "clips": [
                {"filename": "en_01.caf", "language": "en", "description": "TED talk excerpt", "approximate_wpm": 150},
                {"filename": "ru_01.caf", "language": "ru", "description": "News anchor", "approximate_wpm": 130}
            ]
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(ClipManifest.self, from: json)
        #expect(manifest.clips.count == 2)
        #expect(manifest.clips[0].filename == "en_01.caf")
        #expect(manifest.clips[0].language == "en")
        #expect(manifest.clips[0].description == "TED talk excerpt")
        #expect(manifest.clips[0].approximateWPM == 150)
        #expect(manifest.clips[1].language == "ru")
    }

    @Test func parsesManifestWithOptionalWPM() throws {
        let json = """
        {
            "clips": [
                {"filename": "ja_01.caf", "language": "ja", "description": "NHK news"}
            ]
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(ClipManifest.self, from: json)
        #expect(manifest.clips[0].approximateWPM == nil)
    }

    @Test func filtersClipsByLanguage() {
        let manifest = ClipManifest(clips: [
            ClipEntry(filename: "en_01.caf", language: "en", description: "test"),
            ClipEntry(filename: "ru_01.caf", language: "ru", description: "test"),
            ClipEntry(filename: "en_02.caf", language: "en", description: "test"),
        ])

        let enClips = manifest.clips(forLanguage: "en")
        #expect(enClips.count == 2)
        #expect(enClips.allSatisfy { $0.language == "en" })

        let jaClips = manifest.clips(forLanguage: "ja")
        #expect(jaClips.isEmpty)
    }

    @Test func emptyManifest() throws {
        let json = """
        {"clips": []}
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(ClipManifest.self, from: json)
        #expect(manifest.clips.isEmpty)
    }

    @Test func loadsFromFileURL() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let manifestURL = tempDir.appendingPathComponent(
            "test_manifest_\(UUID().uuidString).json"
        )
        let json = """
        {"clips": [{"filename": "en_01.caf", "language": "en", "description": "test"}]}
        """.data(using: .utf8)!
        try json.write(to: manifestURL)
        defer { try? FileManager.default.removeItem(at: manifestURL) }

        let manifest = try ClipManifest.load(from: manifestURL)
        #expect(manifest.clips.count == 1)
        #expect(manifest.clips[0].filename == "en_01.caf")
    }
}
