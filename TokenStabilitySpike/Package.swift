// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TokenStabilitySpike",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "TokenStabilityLib",
            path: "Sources/TokenStabilityLib"
        ),
        .executableTarget(
            name: "TokenStabilitySpikeCLI",
            dependencies: ["TokenStabilityLib"],
            path: "Sources/TokenStabilitySpikeCLI"
        ),
    ]
)
