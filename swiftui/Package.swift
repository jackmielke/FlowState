// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlowState",
    platforms: [.macOS(.v14)],
    targets: [
        // Logic that must be verifiable without a window, a socket or a microphone.
        // Everything here is pure Foundation on purpose — the app target cannot be
        // unit-tested (it owns AppKit, AVAudioEngine and ScreenCaptureKit), so anything
        // with rules worth proving lives on this side of the line.
        .target(
            name: "FlowStateCore",
            path: "Sources/FlowStateCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "FlowState",
            dependencies: ["FlowStateCore"],
            path: "Sources/FlowState",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FlowStateCoreTests",
            dependencies: ["FlowStateCore"],
            path: "Tests/FlowStateCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
