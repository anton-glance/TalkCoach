// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LangDetectSpike",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "LangDetectSpikeLib",
            path: "Sources/LangDetectSpikeLib"
        ),
        .executableTarget(
            name: "LangDetectSpikeCLI",
            dependencies: ["LangDetectSpikeLib"],
            path: "Sources/LangDetectSpikeCLI"
        ),
        .testTarget(
            name: "LangDetectSpikeTests",
            dependencies: ["LangDetectSpikeLib"],
            path: "Tests/LangDetectSpikeTests"
        ),
    ]
)
