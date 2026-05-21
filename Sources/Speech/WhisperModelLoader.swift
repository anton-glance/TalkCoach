import Foundation

enum WhisperModelLoaderError: Error, Equatable {
    case whisperModelNotFound
    case sileroModelNotFound
}

struct WhisperModelLoader {
    static func whisperModelURL(bundle: Bundle = .main) throws -> URL {
        URL(fileURLWithPath: "/stub/ggml-small.bin")  // stub — real impl searches bundle
    }

    static func sileroModelURL(bundle: Bundle = .main) throws -> URL {
        URL(fileURLWithPath: "/stub/ggml-silero-v5.1.2.bin")  // stub
    }
}
