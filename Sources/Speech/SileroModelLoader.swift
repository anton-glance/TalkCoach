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

    /// The resource root of the running app bundle. Pass this as `bundleResourceRoot` at
    /// production call sites so the resolver checks the bundle first. Tests leave
    /// `bundleResourceRoot` nil (the default) so the bundle branch is skipped entirely,
    /// keeping them immune to whatever models happen to be bundled.
    nonisolated static var mainBundleResourceRoot: URL? {
        Bundle.main.resourcePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Full path to `silero_vad.onnx`.
    ///
    /// Checks `bundleResourceRoot` first (no "TalkCoach" segment in path), then falls back
    /// to Application Support (path includes "TalkCoach/Models"). Pass `bundleResourceRoot`
    /// and `baseURL` to override the respective roots.
    /// Defaults to nil so that test call sites (which pass no argument) skip the bundle
    /// branch entirely. Production call sites pass `SileroModelLoader.mainBundleResourceRoot`
    /// explicitly.
    /// Throws `modelNotFound` if the file is absent in all checked locations.
    nonisolated static func modelPath(
        bundleResourceRoot: URL? = nil,
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
