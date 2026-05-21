import Foundation

enum WhisperModelLoaderError: Error, Equatable {
    case whisperModelNotFound
    case sileroModelNotFound
}

struct WhisperModelLoader {
    static func whisperModelURL(bundle: Bundle = .main) throws -> URL {
        guard let url = bundle.url(forResource: "ggml-small", withExtension: "bin", subdirectory: "Models") else {
            throw WhisperModelLoaderError.whisperModelNotFound
        }
        return url
    }

    static func sileroModelURL(bundle: Bundle = .main) throws -> URL {
        guard let url = bundle.url(forResource: "ggml-silero-v5.1.2", withExtension: "bin", subdirectory: "Models") else {
            throw WhisperModelLoaderError.sileroModelNotFound
        }
        return url
    }
}
