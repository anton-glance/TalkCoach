import Foundation
import OSLog

/// Locates the Parakeet TDT v3 int8 ONNX model directory on disk.
///
/// Resolution order:
///   1. bundleResourceRoot/Models/parakeet-tdt-v3-int8/  (bundle — no "TalkCoach" segment)
///   2. appSupportRoot/TalkCoach/Models/parakeet-tdt-v3-int8/  (Application Support)
struct ParakeetModelLoader {
    nonisolated(unsafe) static let requiredFiles: [String] = [
        "encoder-model.int8.onnx",
        "decoder_joint-model.int8.onnx",
        "vocab.txt",
        "nemo128.onnx"
    ]

    enum LoaderError: Error, Equatable {
        case modelDirectoryNotFound
    }

    /// URL of the model directory.
    ///
    /// Checks the bundle resource root first (no "TalkCoach" segment in path), then falls back
    /// to Application Support (path includes "TalkCoach/Models"). Pass `bundleResourceRoot`
    /// and `baseURL` to override the respective roots (testing only).
    /// Throws `modelDirectoryNotFound` if the directory is absent or any required file is missing
    /// in both locations.
    nonisolated static func modelDirectoryURL(
        bundleResourceRoot: URL? = Bundle.main.resourcePath.map { URL(fileURLWithPath: $0, isDirectory: true) },
        baseURL: URL? = nil
    ) throws -> URL {
        // Step 1: bundle candidate — no "TalkCoach" segment
        if let bundleRoot = bundleResourceRoot {
            let candidate = bundleRoot
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent("parakeet-tdt-v3-int8", isDirectory: true)
            if let valid = validatedModelDir(candidate) {
                Logger.speech.info("ParakeetModelLoader: resolved from bundle at \(valid.path)")
                return valid
            }
        }

        // Step 2: Application Support candidate — retains "TalkCoach/Models" segment
        let appSupportRoot: URL
        if let base = baseURL {
            appSupportRoot = base
        } else {
            do {
                appSupportRoot = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: false
                )
            } catch {
                Logger.speech.error("ParakeetModelLoader: cannot locate Application Support — \(error)")
                throw LoaderError.modelDirectoryNotFound
            }
        }

        let appSupportCandidate = appSupportRoot
            .appendingPathComponent("TalkCoach", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("parakeet-tdt-v3-int8", isDirectory: true)
        if let valid = validatedModelDir(appSupportCandidate) {
            Logger.speech.info("ParakeetModelLoader: resolved from Application Support at \(valid.path)")
            return valid
        }

        // Step 3: neither location has a valid model directory
        Logger.speech.error("ParakeetModelLoader: model directory not found at \(appSupportCandidate.path)")
        throw LoaderError.modelDirectoryNotFound
    }

    /// Returns `dir` if it exists as a directory and every name in `requiredFiles` is present
    /// inside it; otherwise returns nil.
    private nonisolated static func validatedModelDir(_ dir: URL) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }
        for filename in Self.requiredFiles {
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(filename).path) else {
                return nil
            }
        }
        return dir
    }
}
