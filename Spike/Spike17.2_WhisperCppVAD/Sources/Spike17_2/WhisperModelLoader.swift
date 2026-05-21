import Foundation

public enum ModelSize: String {
    case small  = "small"
    case medium = "medium"
}

public struct WhisperModelLoader {
    private static let whisperBase = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
    private static let vadBase     = "https://huggingface.co/ggml-org/whisper-vad/resolve/main"

    public static func whisperModelPath(size: ModelSize, modelsDir: URL) -> URL {
        modelsDir.appendingPathComponent("ggml-\(size.rawValue).bin")
    }

    public static func vadModelPath(modelsDir: URL) -> URL {
        modelsDir.appendingPathComponent("ggml-silero-v5.1.2.bin")
    }

    public static func downloadIfNeeded(url: URL, destination: URL) async throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            print("[download] already present: \(destination.lastPathComponent)")
            return
        }
        print("[download] downloading \(destination.lastPathComponent) ...")
        let (tmpURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let dir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tmpURL, to: destination)
        print("[download] saved to \(destination.path)")
    }

    public static func downloadWhisper(size: ModelSize, modelsDir: URL) async throws {
        let dest = whisperModelPath(size: size, modelsDir: modelsDir)
        let src  = URL(string: "\(whisperBase)/ggml-\(size.rawValue).bin")!
        try await downloadIfNeeded(url: src, destination: dest)
    }

    public static func downloadVAD(modelsDir: URL) async throws {
        let dest = vadModelPath(modelsDir: modelsDir)
        let src  = URL(string: "\(vadBase)/ggml-silero-v5.1.2.bin")!
        try await downloadIfNeeded(url: src, destination: dest)
    }
}
