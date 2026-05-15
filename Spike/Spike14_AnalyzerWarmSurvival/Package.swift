// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Spike14",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Spike14",
            path: "Sources/Spike14"
        ),
    ]
)
