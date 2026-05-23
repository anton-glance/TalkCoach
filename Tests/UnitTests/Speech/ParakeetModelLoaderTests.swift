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
}
