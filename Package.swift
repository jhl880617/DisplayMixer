// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DisplayMixer",
    platforms: [
        .macOS("15.0")
    ],
    targets: [
        .executableTarget(
            name: "DisplayMixer",
            path: "Sources/DisplayMixer"
        )
    ]
)
