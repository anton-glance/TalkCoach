// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MicTapTightenSpike",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "MicTapTightenSpikeCLI",
            path: "Sources/MicTapTightenSpikeCLI",
            swiftSettings: [
                .unsafeFlags(["-warnings-as-errors"]),
            ]
        ),
    ]
)
