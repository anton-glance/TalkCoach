// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ShoutingSpike",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "ShoutingSpikeLib",
            path: "Sources/ShoutingSpikeLib"
        ),
        .executableTarget(
            name: "ShoutingSpikeCLI",
            dependencies: ["ShoutingSpikeLib"],
            path: "Sources/ShoutingSpikeCLI"
        ),
        .testTarget(
            name: "ShoutingSpikeLibTests",
            dependencies: ["ShoutingSpikeLib"],
            path: "Tests/ShoutingSpikeLibTests"
        ),
    ]
)
