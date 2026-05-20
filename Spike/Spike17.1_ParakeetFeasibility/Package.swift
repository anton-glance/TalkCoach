// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Spike17_1",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.14.3"),
    ],
    targets: [
        .target(
            name: "Spike17_1",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Spike17_1",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreML"),
            ]
        ),
        .executableTarget(
            name: "Spike17_1CLI",
            dependencies: [
                "Spike17_1",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Spike17_1CLI",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "Spike17_1Eval",
            path: "Sources/Spike17_1Eval"
        ),
        .testTarget(
            name: "Spike17_1Tests",
            dependencies: ["Spike17_1"],
            path: "Tests/Spike17_1Tests",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
            ]
        ),
    ]
)
