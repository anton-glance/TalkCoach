// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MicCoexistSpike",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "MicCoexistSpikeCLI",
            path: "Sources/MicCoexistSpikeCLI"
        ),
    ]
)
