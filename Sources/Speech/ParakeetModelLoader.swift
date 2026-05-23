import Foundation
import OSLog

/// Locates the Parakeet TDT v3 int8 ONNX model directory on disk.
///
/// Expected layout inside the app bundle:
///   Resources/Models/parakeet-tdt-v3-int8/model.onnx (and companion files)
struct ParakeetModelLoader {
    enum LoaderError: Error {
        case modelDirectoryNotFound
    }

    /// URL of the model directory bundled inside the app.
    nonisolated static func modelDirectoryURL(bundle: Bundle = .main) throws -> URL {
        guard let url = bundle.url(
            forResource: "parakeet-tdt-v3-int8",
            withExtension: nil,
            subdirectory: "Models"
        ) else {
            Logger.speech.error("ParakeetModelLoader: model directory not found in bundle")
            throw LoaderError.modelDirectoryNotFound
        }
        return url
    }
}
