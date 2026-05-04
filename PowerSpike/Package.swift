// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PowerSpike",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "PowerSpikeLib",
            path: "Sources/PowerSpikeLib"
        ),
        .executableTarget(
            name: "PowerSpikeCLI",
            dependencies: ["PowerSpikeLib"],
            path: "Sources/PowerSpikeCLI"
        ),
    ]
)
