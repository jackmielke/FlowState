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

    /// Two styles sharing a label would be two identical-looking buttons in the picker,
    /// and a loop filename collision the moment either of them is given one.
    func test_labelsAndFilenamesAreUnique() {
        XCTAssertEqual(Set(MotionStyle.allCases.map(\.label)).count, MotionStyle.allCases.count)
        XCTAssertEqual(Set(MotionStyle.allCases.map(\.assetBaseName)).count, MotionStyle.allCases.count)
        XCTAssertFalse(MotionStyle.allCases.contains { $0.blurb.isEmpty })
    }

    /// The rule every one of these is composed around: a transcript in 11-point grey has
    /// to stay readable on top of it, so the ground is dark and the *bright* end of the
    /// palette is the exception rather than the field. A new style whose first stop came
    /// out pale would pass every other test here and be unusable behind text.
    func test_everyPaletteRunsDarkToBright() {
        func luma(_ v: UInt32) -> Double {
            let r = Double((v >> 16) & 0xFF) / 255
            let g = Double((v >> 8) & 0xFF) / 255
            let b = Double(v & 0xFF) / 255
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        for style in MotionStyle.allCases {
            let stops = style.palette.map(luma)
            XCTAssertLessThan(stops[0], 0.10, "\(style.rawValue) has no dark ground to sit text on")
            XCTAssertGreaterThan(stops[3], stops[0], "\(style.rawValue) palette is not dark to bright")
            // Monotonic, not just dark-to-bright at the ends: `ramp` walks the four stops
            // with one number, so a stop out of order is a band that gets darker as the
            // value rises — visible as a seam across the middle of the picture.
            XCTAssertEqual(stops, stops.sorted(), "\(style.rawValue) stops are out of order")
        }
    }

    /// Every still in the app comes from `stillPhase` — the frozen frame under Reduce
    /// Motion, the frozen frame behind another window, the preview thumbnails. Zero is the
    /// one moment all of these look like a flat gradient, so a still taken there advertises
    /// nothing.
    func test_stillsAreTakenMidFlowNotAtZero() {
        for style in MotionStyle.allCases {
            XCTAssertGreaterThan(style.stillPhase, 0, "\(style.rawValue) freezes at t = 0")
            // Scaled by the style's own speed, so a slow style gets the same amount of
            // development rather than the same number of seconds.
            XCTAssertEqual(style.stillPhase, 12.0 * style.speed, accuracy: 1e-9)
        }
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

    // MARK: - Loops that are there but do not play

    /// The case this whole predicate exists for: `ocean.mov` is on disk and unplayable, so
    /// the `ocean.mp4` beside it wins. Existence alone would have picked the broken one and
    /// drawn black.
    func test_aBrokenLoopLosesToAGoodOneBesideIt() {
        let found = MotionAssets.asset(
            for: .ocean, in: [user],
            exists: onDisk([user.path + "/ocean.mov", user.path + "/ocean.mp4"]),
            broken: { $0.path.hasSuffix("ocean.mov") })
        XCTAssertEqual(found?.path, user.path + "/ocean.mp4")
    }

    /// And when every candidate is broken the style goes back down the chain rather than
    /// insisting on a file that cannot be played — a bad download costs you one backdrop,
    /// not the picture.
    func test_everyLoopBrokenFallsBackToTheShader() {
        let src = MotionAssets.source(
            for: .rain, directories: [user, bundled],
            assetsEnabled: true, shaderAvailable: true,
            exists: { _ in true },
            broken: { _ in true })
        XCTAssertEqual(src, .shader)
    }

    /// With no Metal either, it still draws something.
    func test_everyLoopBrokenAndNoMetalStillDrawsSomething() {
        let src = MotionAssets.source(
            for: .embers, directories: [user],
            assetsEnabled: true, shaderAvailable: false,
            exists: { _ in true },
            broken: { _ in true })
        XCTAssertEqual(src, .painted)
    }

    /// Nothing is broken until something says so. Every existing caller passes no
    /// predicate at all and must keep resolving exactly as it did.
    func test_nothingIsBrokenByDefault() {
        let src = MotionAssets.source(for: .prism, directories: [user],
                                      assetsEnabled: true, shaderAvailable: true,
                                      exists: onDisk([user.path + "/prism.mp4"]))
        XCTAssertEqual(src, .asset(user.appendingPathComponent("prism.mp4")))
    }

    // MARK: - What may be installed

    func test_onlyVideoContainersAreAccepted() {
        XCTAssertNil(MotionAssetPolicy.rejection(name: "loop.mp4", extension: "mp4", bytes: 4_000_000))
        XCTAssertNil(MotionAssetPolicy.rejection(name: "loop.MOV", extension: "MOV", bytes: nil))
        XCTAssertNotNil(MotionAssetPolicy.rejection(name: "sky.gif", extension: "gif", bytes: 100))
        XCTAssertNotNil(MotionAssetPolicy.rejection(name: "sky.png", extension: "png", bytes: nil))
    }

    /// The safe default. This folder sits beside the transcripts and is filled from a file
    /// picker, so the 4K master a stock site offers has to be refused before it is copied
    /// rather than discovered as half a gigabyte of Application Support later.
    func test_anAbsurdlyLargeLoopIsRefusedBeforeItIsCopied() {
        let over = MotionAssetPolicy.rejection(name: "master.mov", extension: "mov",
                                               bytes: MotionAssetPolicy.maxBytes + 1)
        XCTAssertNotNil(over)
        XCTAssertTrue(try XCTUnwrap(over).contains("master.mov"), "the refusal has to name the file")
        XCTAssertNil(MotionAssetPolicy.rejection(name: "master.mov", extension: "mov",
                                                 bytes: MotionAssetPolicy.maxBytes))
    }

    /// A size that could not be read is not a reason to refuse — the copy fails honestly
    /// a moment later if the file is really unreadable.
    func test_anUnknownSizeIsNotARefusal() {
        XCTAssertNil(MotionAssetPolicy.rejection(name: "loop.m4v", extension: "m4v", bytes: nil))
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
