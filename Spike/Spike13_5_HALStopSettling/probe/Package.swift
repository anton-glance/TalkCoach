// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "probe",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "probe",
            path: "Sources/probe"
        ),
    ]
)
