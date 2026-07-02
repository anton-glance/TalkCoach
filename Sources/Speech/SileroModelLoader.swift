import Foundation
import OSLog

/// Locates the Silero VAD v5 ONNX model on disk.
///
/// Resolution order:
///   1. bundleResourceRoot/Models/silero_vad.onnx  (bundle — no "TalkCoach" segment)
///   2. appSupportRoot/TalkCoach/Models/silero_vad.onnx  (Application Support)
struct SileroModelLoader {
    enum LoaderError: Error, Equatable {
        case modelNotFound
    }

    /// Full path to `silero_vad.onnx`.
    ///
    /// Checks the bundle resource root first (no "TalkCoach" segment in path), then falls back
    /// to Application Support (path includes "TalkCoach/Models"). Pass `bundleResourceRoot`
    /// and `baseURL` to override the respective roots (testing only).
    /// Throws `modelNotFound` if the file is absent in both locations.
    nonisolated static func modelPath(
        bundleResourceRoot: URL? = Bundle.main.resourcePath.map { URL(fileURLWithPath: $0, isDirectory: true) },
        baseURL: URL? = nil
    ) throws -> String {
        // Step 1: bundle candidate — no "TalkCoach" segment
        if let bundleRoot = bundleResourceRoot {
            let candidate = bundleRoot
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent("silero_vad.onnx")
            if FileManager.default.fileExists(atPath: candidate.path) {
                Logger.speech.info("SileroModelLoader: resolved from bundle at \(candidate.path)")
                return candidate.path
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
                Logger.speech.error("SileroModelLoader: cannot locate Application Support — \(error)")
                throw LoaderError.modelNotFound
            }
        }

        let appSupportCandidate = appSupportRoot
            .appendingPathComponent("TalkCoach", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("silero_vad.onnx")
        if FileManager.default.fileExists(atPath: appSupportCandidate.path) {
            Logger.speech.info("SileroModelLoader: resolved from Application Support at \(appSupportCandidate.path)")
            return appSupportCandidate.path
        }

        // Step 3: neither location has the model file
        Logger.speech.error("SileroModelLoader: silero_vad.onnx not found at \(appSupportCandidate.path)")
        throw LoaderError.modelNotFound
    }
}
