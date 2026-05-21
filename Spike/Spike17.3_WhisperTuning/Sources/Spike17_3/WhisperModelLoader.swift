import Foundation

public enum ModelSize: String {
    case small  = "small"
    case medium = "medium"
}

public enum WhisperModelLoader {

    private static let whisperBaseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
    private static let vadURL = "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"

    public static func downloadWhisper(size: ModelSize, modelsDir: URL) async throws {
        let filename = "ggml-\(size.rawValue).bin"
        let dest = modelsDir.appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            print("[download] \(filename) already present, skipping")
            return
        }
        let url = URL(string: "\(whisperBaseURL)/\(filename)")!
        print("[download] fetching \(url) → \(dest.lastPathComponent)")
        let (tmp, _) = try await URLSession.shared.download(from: url)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: tmp, to: dest)
        print("[download] done: \(dest.lastPathComponent)")
    }

    public static func downloadVAD(modelsDir: URL) async throws {
        let filename = "ggml-silero-v5.1.2.bin"
        let dest = modelsDir.appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            print("[download] \(filename) already present, skipping")
            return
        }
        let url = URL(string: vadURL)!
        print("[download] fetching \(url) → \(dest.lastPathComponent)")
        let (tmp, _) = try await URLSession.shared.download(from: url)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: tmp, to: dest)
        print("[download] done: \(dest.lastPathComponent)")
    }
}
