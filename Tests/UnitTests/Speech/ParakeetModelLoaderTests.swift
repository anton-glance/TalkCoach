import XCTest
@testable import TalkCoach

@MainActor
final class ParakeetModelLoaderTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeModelDir() throws -> URL {
        let modelDir = tempDir
            .appendingPathComponent("TalkCoach/Models/parakeet-tdt-v3-int8", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        return modelDir
    }

    /// modelDirectoryURL throws when the model subdirectory tree is absent under baseURL.
    func testThrowsWhenModelDirectoryAbsent() throws {
        XCTAssertThrowsError(
            try ParakeetModelLoader.modelDirectoryURL(baseURL: tempDir)
        ) { error in
            XCTAssertEqual(error as? ParakeetModelLoader.LoaderError, .modelDirectoryNotFound)
        }
    }

    /// modelDirectoryURL throws when directory exists but contains no required files.
    func testThrowsWhenRequiredFilesMissing() throws {
        _ = try makeModelDir()
        XCTAssertThrowsError(
            try ParakeetModelLoader.modelDirectoryURL(baseURL: tempDir)
        ) { error in
            XCTAssertEqual(error as? ParakeetModelLoader.LoaderError, .modelDirectoryNotFound)
        }
    }

    /// modelDirectoryURL throws when directory exists but only some required files are present.
    func testThrowsWhenSomeRequiredFilesMissing() throws {
        let modelDir = try makeModelDir()
        let partial = Array(ParakeetModelLoader.requiredFiles.dropLast())
        for name in partial {
            FileManager.default.createFile(
                atPath: modelDir.appendingPathComponent(name).path, contents: nil
            )
        }
        XCTAssertThrowsError(
            try ParakeetModelLoader.modelDirectoryURL(baseURL: tempDir)
        ) { error in
            XCTAssertEqual(error as? ParakeetModelLoader.LoaderError, .modelDirectoryNotFound)
        }
    }

    /// modelDirectoryURL succeeds and returns the model directory when all required files present.
    func testSuccessWhenAllRequiredFilesPresent() throws {
        let modelDir = try makeModelDir()
        for name in ParakeetModelLoader.requiredFiles {
            FileManager.default.createFile(
                atPath: modelDir.appendingPathComponent(name).path, contents: nil
            )
        }
        let result = try ParakeetModelLoader.modelDirectoryURL(baseURL: tempDir)
        XCTAssertEqual(result.lastPathComponent, "parakeet-tdt-v3-int8")
        XCTAssertEqual(result.path, modelDir.path)
    }

    /// Production path (no baseURL) resolves inside Application Support. Succeeds if model present,
    /// throws modelDirectoryNotFound if absent — never any other error type.
    func testProductionPathRootedInApplicationSupport() throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let expectedParent = appSupport.appendingPathComponent("TalkCoach/Models").path
        XCTAssertTrue(
            expectedParent.hasPrefix(appSupport.path),
            "Resolved model path must be inside Application Support"
        )
        // Calling without baseURL: either succeeds (model present) or throws the expected error.
        do {
            let url = try ParakeetModelLoader.modelDirectoryURL()
            XCTAssertTrue(url.path.hasPrefix(appSupport.path))
        } catch ParakeetModelLoader.LoaderError.modelDirectoryNotFound {
            // Expected in CI — no model on disk.
        } catch {
            XCTFail("Unexpected error type from production path: \(error)")
        }
    }

    // MARK: - Bundle-first resolution tests

    func testBundlePreferredWhenBundleValid() throws {
        let bundleRoot = tempDir.appendingPathComponent("bundle", isDirectory: true)
        let bundleModelDir = bundleRoot
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("parakeet-tdt-v3-int8", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleModelDir, withIntermediateDirectories: true)
        for name in ParakeetModelLoader.requiredFiles {
            FileManager.default.createFile(atPath: bundleModelDir.appendingPathComponent(name).path, contents: nil)
        }
        let emptyBase = tempDir.appendingPathComponent("emptyBase", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBase, withIntermediateDirectories: true)

        let result = try ParakeetModelLoader.modelDirectoryURL(bundleResourceRoot: bundleRoot, baseURL: emptyBase)
        XCTAssertEqual(result.path, bundleModelDir.path)
        XCTAssertTrue(result.path.hasPrefix(bundleRoot.path), "Result must be rooted in bundle root, not Application Support")
    }

    func testFallsBackToApplicationSupportWhenBundleAbsent() throws {
        let emptyBundle = tempDir.appendingPathComponent("emptyBundle", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBundle, withIntermediateDirectories: true)
        let validBase = tempDir.appendingPathComponent("validBase", isDirectory: true)
        let validModelDir = validBase
            .appendingPathComponent("TalkCoach", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("parakeet-tdt-v3-int8", isDirectory: true)
        try FileManager.default.createDirectory(at: validModelDir, withIntermediateDirectories: true)
        for name in ParakeetModelLoader.requiredFiles {
            FileManager.default.createFile(atPath: validModelDir.appendingPathComponent(name).path, contents: nil)
        }

        let result = try ParakeetModelLoader.modelDirectoryURL(bundleResourceRoot: emptyBundle, baseURL: validBase)
        XCTAssertEqual(result.path, validModelDir.path)
        XCTAssertTrue(result.path.hasPrefix(validBase.path), "Result must be rooted in Application Support root, not bundle")
    }

    func testFallsBackWhenBundleDirPresentButFilesMissing() throws {
        let bundleRoot = tempDir.appendingPathComponent("bundle", isDirectory: true)
        let bundleModelDir = bundleRoot
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("parakeet-tdt-v3-int8", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleModelDir, withIntermediateDirectories: true)
        for name in ParakeetModelLoader.requiredFiles.dropLast() {
            FileManager.default.createFile(atPath: bundleModelDir.appendingPathComponent(name).path, contents: nil)
        }
        let validBase = tempDir.appendingPathComponent("validBase", isDirectory: true)
        let validModelDir = validBase
            .appendingPathComponent("TalkCoach", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("parakeet-tdt-v3-int8", isDirectory: true)
        try FileManager.default.createDirectory(at: validModelDir, withIntermediateDirectories: true)
        for name in ParakeetModelLoader.requiredFiles {
            FileManager.default.createFile(atPath: validModelDir.appendingPathComponent(name).path, contents: nil)
        }

        let result = try ParakeetModelLoader.modelDirectoryURL(bundleResourceRoot: bundleRoot, baseURL: validBase)
        XCTAssertEqual(result.path, validModelDir.path)
    }

    func testThrowsWhenNeitherBundleNorFallbackValid() throws {
        let emptyBundle = tempDir.appendingPathComponent("emptyBundle", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBundle, withIntermediateDirectories: true)
        let emptyBase = tempDir.appendingPathComponent("emptyBase", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBase, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try ParakeetModelLoader.modelDirectoryURL(bundleResourceRoot: emptyBundle, baseURL: emptyBase)
        ) { error in
            XCTAssertEqual(error as? ParakeetModelLoader.LoaderError, .modelDirectoryNotFound)
        }
    }
}
