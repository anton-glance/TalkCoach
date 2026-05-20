// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Spike17_1_5",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Same SHA as Spike17.1: FluidAudio 0.14.7
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "8048812869b0c7c6fa393e564a4fb6f95126ba23"
        ),
    ],
    targets: [
        .target(
            name: "Spike17_1_5",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Spike17_1_5",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreML"),
            ]
        ),
        .executableTarget(
            name: "Spike17_1_5CLI",
            dependencies: [
                "Spike17_1_5",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Spike17_1_5CLI",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "Spike17_1_5Eval",
            path: "Sources/Spike17_1_5Eval"
        ),
    ]
)
