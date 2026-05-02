// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParakeetSpike",
    platforms: [.macOS(.v26)],
    products: [],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            from: "0.9.0"
        ),
    ],
    targets: [
        .target(
            name: "WPMCalcCopy",
            path: "Sources/WPMCalcCopy"
        ),
        .executableTarget(
            name: "ParakeetSpikeCLI",
            dependencies: [
                "WPMCalcCopy",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/ParakeetSpikeCLI"
        ),
    ]
)
