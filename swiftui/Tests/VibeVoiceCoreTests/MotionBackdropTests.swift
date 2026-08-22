import XCTest
@testable import VibeVoiceCore

/// Which renderer a moving backdrop lands on, and how often it is allowed to draw.
///
/// Both questions are here rather than in the view because both have a wrong answer that
/// is invisible until it is expensive: a shader chosen on a build with no Metal library
/// crashes at draw time, and a backdrop that keeps animating behind another window costs
/// an afternoon of battery to notice.
final class MotionBackdropTests: XCTestCase {

    private let user = URL(fileURLWithPath: "/Users/x/Library/Application Support/VibeVoice/Motion",
                           isDirectory: true)
    private let bundled = URL(fileURLWithPath: "/Applications/VibeVoice.app/Contents/Resources/Motion",
                              isDirectory: true)

    private func onDisk(_ paths: Set<String>) -> (URL) -> Bool {
        { paths.contains($0.path) }
    }

    // MARK: - The styles themselves

    /// The shader binds the palette to c0…c3 and the painted fallback indexes it up to
    /// [3]. A style with three colours would compile and then crash on whichever machine
    /// happened to fall back.
    func test_everyStyleHasExactlyFourStops() {
        for style in MotionStyle.allCases {
            XCTAssertEqual(style.palette.count, 4, "\(style.rawValue) palette")
        }
    }

    /// The function name is the entire contract with Motion.metal — nothing checks it at
    /// compile time, in either language.
    func test_shaderFunctionNamesAreUniqueAndPrefixed() {
        let names = MotionStyle.allCases.map(\.shaderFunction)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(MotionStyle.ocean.shaderFunction, "motion_ocean")
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("motion_") })
    }

    // MARK: - Finding a loop

    /// Directory order is preference order: a loop the user installed beats one that
    /// shipped in the bundle, whatever the extensions involved.
    func test_theUsersOwnLoopWinsOverTheBundledOne() {
        let found = MotionAssets.asset(
            for: .ocean, in: [user, bundled],
            exists: onDisk([user.path + "/ocean.mp4", bundled.path + "/ocean.mov"]))
        XCTAssertEqual(found?.path, user.path + "/ocean.mp4")
    }

    /// A folder holding both must resolve the same way on every launch, so the order the
    /// extensions are tried in is fixed rather than whatever the filesystem lists first.
    func test_extensionOrderIsStable() {
        let found = MotionAssets.asset(
            for: .silk, in: [user],
            exists: onDisk([user.path + "/silk.mp4", user.path + "/silk.mov"]))
        XCTAssertEqual(found?.path, user.path + "/silk.mov")
    }

    func test_aLoopForOneStyleIsNotALoopForAnother() {
        XCTAssertNil(MotionAssets.asset(for: .aurora, in: [user],
                                        exists: onDisk([user.path + "/ocean.mp4"])))
    }

    // MARK: - The fallback chain

    func test_aLoopOnDiskIsPreferredToTheShader() {
        let src = MotionAssets.source(for: .clouds, directories: [user],
                                      assetsEnabled: true, shaderAvailable: true,
                                      exists: onDisk([user.path + "/clouds.m4v"]))
        XCTAssertEqual(src, .asset(user.appendingPathComponent("clouds.m4v")))
    }

    /// The switch is the way back to the drawn version without deleting a file the user
    /// may have gone to some trouble to make.
    func test_switchingAssetsOffIgnoresTheFileWithoutDeletingIt() {
        let src = MotionAssets.source(for: .clouds, directories: [user],
                                      assetsEnabled: false, shaderAvailable: true,
                                      exists: onDisk([user.path + "/clouds.m4v"]))
        XCTAssertEqual(src, .shader)
    }

    /// The case that matters: `swift run` outside the bundle, or a build made on a Mac
    /// with no Metal toolchain. `ShaderLibrary.default` does not fail politely there.
    func test_noMetalLibraryMeansPaintedNotShader() {
        let src = MotionAssets.source(for: .nebula, directories: [user],
                                      assetsEnabled: true, shaderAvailable: false,
                                      exists: onDisk([]))
        XCTAssertEqual(src, .painted)
    }

    func test_noAssetAndNoMetalStillDrawsSomething() {
        for style in MotionStyle.allCases {
            let src = MotionAssets.source(for: style, directories: [],
                                          assetsEnabled: true, shaderAvailable: false,
                                          exists: { _ in false })
            XCTAssertEqual(src, .painted, "\(style.rawValue) had nothing to fall back to")
        }
    }

    // MARK: - Frame budget

    /// Nothing animates behind another window. This is the single most important number
    /// in the feature and the one nobody would ever see going wrong.
    func test_anOccludedWindowDrawsNoFrames() {
        for source in [MotionSource.shader, .painted, .asset(user)] {
            XCTAssertEqual(MotionBudget.fps(source: source, occluded: true), 0)
            XCTAssertNil(MotionBudget.interval(source: source, occluded: true))
        }
    }

    /// Reduce Motion means a still picture, not a slow one.
    func test_reduceMotionFreezesRatherThanSlows() {
        XCTAssertEqual(MotionBudget.fps(source: .shader, reduceMotion: true), 0)
        XCTAssertNil(MotionBudget.interval(source: .painted, reduceMotion: true))
    }

    /// A video loop has its own clock; SwiftUI ticking alongside it would be pure waste.
    func test_aVideoLoopNeedsNoSwiftUIFrames() {
        XCTAssertEqual(MotionBudget.fps(source: .asset(user)), 0)
    }

    /// The painted fallback is dozens of gradient fills per frame against the shader's
    /// one pass, so it is deliberately given fewer of them.
    func test_thePaintedFallbackIsBudgetedBelowTheShader() {
        XCTAssertLessThan(MotionBudget.fps(source: .painted),
                          MotionBudget.fps(source: .shader))
        XCTAssertLessThan(MotionBudget.fps(source: .painted, preview: true),
                          MotionBudget.fps(source: .painted))
    }

    /// Six of these run at once in the Settings grid, so a preview costs half of what the
    /// real thing does.
    func test_previewsAreCheaperThanTheRealThing() throws {
        XCTAssertLessThan(MotionBudget.fps(source: .shader, preview: true),
                          MotionBudget.fps(source: .shader))
        XCTAssertEqual(try XCTUnwrap(MotionBudget.interval(source: .shader)), 1.0 / 30, accuracy: 1e-9)
    }
}
