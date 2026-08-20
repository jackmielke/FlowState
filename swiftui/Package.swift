// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeVoice",
    platforms: [.macOS(.v14)],
    targets: [
        // Logic that must be verifiable without a window, a socket or a microphone.
        // Everything here is pure Foundation on purpose — the app target cannot be
        // unit-tested (it owns AppKit, AVAudioEngine and ScreenCaptureKit), so anything
        // with rules worth proving lives on this side of the line.
        .target(
            name: "VibeVoiceCore",
            path: "Sources/VibeVoiceCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "VibeVoice",
            dependencies: ["VibeVoiceCore"],
            path: "Sources/VibeVoice",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VibeVoiceCoreTests",
            dependencies: ["VibeVoiceCore"],
            path: "Tests/VibeVoiceCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
