// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WPMSpike",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "WPMCalculatorLib",
            path: "Sources/WPMCalculatorLib"
        ),
        .executableTarget(
            name: "WPMSpikeCLI",
            dependencies: ["WPMCalculatorLib"],
            path: "Sources/WPMSpikeCLI"
        ),
        .testTarget(
            name: "WPMCalculatorTests",
            dependencies: ["WPMCalculatorLib"],
            path: "Tests/WPMCalculatorTests"
        ),
    ]
)
