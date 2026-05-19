// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Spike16",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "Spike16",
            path: "Sources/Spike16"
        ),
        .executableTarget(
            name: "Spike16CLI",
            dependencies: ["Spike16"],
            path: "Sources/Spike16CLI",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "Spike16Eval",
            path: "Sources/Spike16Eval"
        ),
        .testTarget(
            name: "Spike16Tests",
            dependencies: ["Spike16"],
            path: "Tests/Spike16Tests"
        ),
    ]
)
