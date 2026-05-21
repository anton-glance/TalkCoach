// swift-tools-version: 6.0
import PackageDescription
import Foundation

// SPM evaluates Package.swift from the package root directory.
// spikeRoot = Spike17.3_WhisperTuning/; build artifacts live in Spike17.2_WhisperCppVAD/build/.
// Use URL.standardizedFileURL to resolve canonical paths without ".." components,
// which confuses clang's module map include resolution.
let spikeRoot  = FileManager.default.currentDirectoryPath
let spike17_2  = URL(fileURLWithPath: "\(spikeRoot)/../Spike17.2_WhisperCppVAD").standardizedFileURL.path
let whisperInc = "\(spike17_2)/whisper.cpp/include"
let ggmlInc    = "\(spike17_2)/whisper.cpp/ggml/include"
let buildSrc   = "\(spike17_2)/build/src"
let buildGgml  = "\(spike17_2)/build/ggml/src"
let buildMetal = "\(spike17_2)/build/ggml/src/ggml-metal"
let buildBlas  = "\(spike17_2)/build/ggml/src/ggml-blas"

let package = Package(
    name: "Spike17_3",
    platforms: [.macOS(.v14)],
    targets: [
        // Thin C bridge: CWhisper.h declares wrapper functions (no ggml types).
        // WhisperBridge.c implements them plus the new threshold-aware VAD function.
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I", whisperInc, "-I", ggmlInc]),
            ]
        ),

        // Swift library: StreamingWhisperVoiceDetector + TokenEvent + model loader.
        // Links against libwhisper.a and ggml component libs from #17.2 build (no rebuild needed).
        .target(
            name: "Spike17_3",
            dependencies: ["CWhisper"],
            path: "Sources/Spike17_3",
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
            name: "Spike17_3CLI",
            dependencies: ["Spike17_3"],
            path: "Sources/Spike17_3CLI"
        ),

        // Eval executable: pure Swift, reads CSVs + manifest, scores all 12 criteria.
        .executableTarget(
            name: "Spike17_3Eval",
            path: "Sources/Spike17_3Eval"
        ),
    ]
)
