import Foundation
import OSLog

/// Locates the Silero VAD v5 ONNX model on disk.
///
/// Expected path:
///   ~/Library/Application Support/TalkCoach/Models/silero_vad.onnx
struct SileroModelLoader {
    enum LoaderError: Error, Equatable {
        case modelNotFound
    }

    /// Full path to `silero_vad.onnx`.
    ///
    /// Pass `baseURL` to override the Application Support root (testing only).
    /// Throws `modelNotFound` if the file is absent.
    nonisolated static func modelPath(baseURL: URL? = nil) throws -> String {
        let appSupport: URL
        if let base = baseURL {
            appSupport = base
        } else {
            do {
                appSupport = try FileManager.default.url(
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

        let modelURL = appSupport
            .appendingPathComponent("TalkCoach", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("silero_vad.onnx")

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            Logger.speech.error("SileroModelLoader: silero_vad.onnx not found at \(modelURL.path)")
            throw LoaderError.modelNotFound
        }

        return modelURL.path
    }
}
