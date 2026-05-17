// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Spike15",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Spike15",
            path: "Sources/Spike15",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
