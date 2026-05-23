import Foundation
import OSLog

/// Locates the Parakeet TDT v3 int8 ONNX model directory on disk.
///
/// Expected layout:
///   ~/Library/Application Support/TalkCoach/Models/parakeet-tdt-v3-int8/
///     encoder-model.int8.onnx
///     decoder_joint-model.int8.onnx
///     vocab.txt
///     nemo128.onnx
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
    /// Pass `baseURL` to override the Application Support root (testing only).
    /// When nil, resolves ~/Library/Application Support/TalkCoach/Models/parakeet-tdt-v3-int8/.
    /// Throws `modelDirectoryNotFound` if the directory is absent or any required file is missing.
    nonisolated static func modelDirectoryURL(baseURL: URL? = nil) throws -> URL {
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
                Logger.speech.error("ParakeetModelLoader: cannot locate Application Support — \(error)")
                throw LoaderError.modelDirectoryNotFound
            }
        }

        let modelDir = appSupport
            .appendingPathComponent("TalkCoach", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("parakeet-tdt-v3-int8", isDirectory: true)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelDir.path, isDirectory: &isDir),
              isDir.boolValue else {
            Logger.speech.error("ParakeetModelLoader: model directory not found at \(modelDir.path)")
            throw LoaderError.modelDirectoryNotFound
        }

        for filename in Self.requiredFiles {
            guard FileManager.default.fileExists(atPath: modelDir.appendingPathComponent(filename).path) else {
                Logger.speech.error("ParakeetModelLoader: missing required file \(filename)")
                throw LoaderError.modelDirectoryNotFound
            }
        }

        return modelDir
    }
}
