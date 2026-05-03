// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LangDetectSpike",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            from: "0.9.0"
        ),
    ],
    targets: [
        .target(
            name: "LangDetectSpikeLib",
            path: "Sources/LangDetectSpikeLib"
        ),
        .executableTarget(
            name: "LangDetectSpikeCLI",
            dependencies: [
                "LangDetectSpikeLib",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/LangDetectSpikeCLI"
        ),
        .testTarget(
            name: "LangDetectSpikeTests",
            dependencies: ["LangDetectSpikeLib"],
            path: "Tests/LangDetectSpikeTests"
        ),
    ]
)
