// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeVoice",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VibeVoice",
            path: "Sources/VibeVoice",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
