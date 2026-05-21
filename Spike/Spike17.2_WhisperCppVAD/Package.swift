// swift-tools-version: 6.0
import PackageDescription
import Foundation

// SPM evaluates Package.swift from the package root directory.
// FileManager.default.currentDirectoryPath gives the correct absolute path at manifest eval time.
let spikeRoot  = FileManager.default.currentDirectoryPath
let whisperInc = "\(spikeRoot)/whisper.cpp/include"
let ggmlInc    = "\(spikeRoot)/whisper.cpp/ggml/include"
let buildSrc   = "\(spikeRoot)/build/src"
let buildGgml  = "\(spikeRoot)/build/ggml/src"
let buildMetal = "\(spikeRoot)/build/ggml/src/ggml-metal"
let buildBlas  = "\(spikeRoot)/build/ggml/src/ggml-blas"

let package = Package(
    name: "Spike17_2",
    platforms: [.macOS(.v14)],
    targets: [
        // Thin C bridge: CWhisper.h declares wrapper functions (no ggml types).
        // WhisperBridge.c implements them by calling the real whisper/vad C API.
        // cSettings provide include paths for whisper.h and ggml.h to WhisperBridge.c.
        // Swift consumers see only CWhisper.h — no ggml include paths needed in Swift.
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I", whisperInc, "-I", ggmlInc]),
            ]
        ),

        // Swift library: StreamingWhisperVoiceDetector + TokenEvent + model loader.
        // Links against libwhisper.a and ggml component libs built by cmake in run_all.sh.
        .target(
            name: "Spike17_2",
            dependencies: ["CWhisper"],
            path: "Sources/Spike17_2",
            linkerSettings: [
                .unsafeFlags([
                    "-L", buildSrc,
                    "-L", buildGgml,
                    "-L", buildMetal,
                    "-L", buildBlas,
                    "-lwhisper",
                    "-lggml",
                    "-lggml-base",
                    "-lggml-cpu",
                    "-lggml-metal",
                    "-lggml-blas",
                    "-lc++",
                    "-framework", "Metal",
                    "-framework", "MetalKit",
                    "-framework", "Accelerate",
                    "-framework", "Foundation",
                ]),
                .linkedFramework("AVFoundation"),
            ]
        ),

        // CLI executable: feeds fixtures through the detector, writes CSV + JSON.
        .executableTarget(
            name: "Spike17_2CLI",
            dependencies: ["Spike17_2"],
            path: "Sources/Spike17_2CLI"
        ),

        // Eval executable: pure Swift, reads CSVs + manifest, scores all 12 criteria.
        .executableTarget(
            name: "Spike17_2Eval",
            path: "Sources/Spike17_2Eval"
        ),
    ]
)
