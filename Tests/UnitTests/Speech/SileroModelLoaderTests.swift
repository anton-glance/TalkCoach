import XCTest
@testable import TalkCoach

@MainActor
final class SileroModelLoaderTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testBundlePreferredWhenBundleValid() throws {
        let bundleRoot = tempDir.appendingPathComponent("bundle", isDirectory: true)
        let bundleModelsDir = bundleRoot.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleModelsDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: bundleModelsDir.appendingPathComponent("silero_vad.onnx").path,
            contents: nil
        )
        let emptyBase = tempDir.appendingPathComponent("emptyBase", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBase, withIntermediateDirectories: true)

        let result = try SileroModelLoader.modelPath(bundleResourceRoot: bundleRoot, baseURL: emptyBase)
        XCTAssertEqual(result, bundleModelsDir.appendingPathComponent("silero_vad.onnx").path)
        XCTAssertTrue(result.hasPrefix(bundleRoot.path), "Result must be rooted in bundle root, not Application Support")
    }

    func testFallsBackToApplicationSupportWhenBundleAbsent() throws {
        let emptyBundle = tempDir.appendingPathComponent("emptyBundle", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBundle, withIntermediateDirectories: true)
        let validBase = tempDir.appendingPathComponent("validBase", isDirectory: true)
        let validModelsDir = validBase
            .appendingPathComponent("TalkCoach", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: validModelsDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: validModelsDir.appendingPathComponent("silero_vad.onnx").path,
            contents: nil
        )

        let result = try SileroModelLoader.modelPath(bundleResourceRoot: emptyBundle, baseURL: validBase)
        XCTAssertEqual(result, validModelsDir.appendingPathComponent("silero_vad.onnx").path)
        XCTAssertTrue(result.hasPrefix(validBase.path), "Result must be rooted in Application Support root, not bundle")
    }

    func testThrowsWhenNeitherBundleNorFallbackValid() throws {
        let emptyBundle = tempDir.appendingPathComponent("emptyBundle", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBundle, withIntermediateDirectories: true)
        let emptyBase = tempDir.appendingPathComponent("emptyBase", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBase, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try SileroModelLoader.modelPath(bundleResourceRoot: emptyBundle, baseURL: emptyBase)
        ) { error in
            XCTAssertEqual(error as? SileroModelLoader.LoaderError, .modelNotFound)
        }
    }
}
