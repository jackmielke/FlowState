import XCTest
@testable import VibeVoiceCore

/// The capture modes and the plan each one produces.
///
/// Two classes of thing are pinned here. The first is the promise to everyone who was
/// using this app before video existed: audio-only must still be a WAV, must still need
/// nothing but the microphone, and must still be the default. The second is the set of
/// encoder constraints that are invisible until they are violated — odd frame dimensions,
/// upscaling, a bit rate with no floor — each of which produces a file that looks fine in
/// a unit test and wrong on screen.
final class CaptureModeTests: XCTestCase {

    // MARK: - Not breaking what already worked

    func test_audioOnlyStillWritesAWav() {
        XCTAssertEqual(CaptureMode.audioOnly.fileExtension, "wav")
        XCTAssertFalse(CaptureMode.audioOnly.isVideo)
        XCTAssertFalse(CaptureMode.audioOnly.capturesScreen)
        XCTAssertFalse(CaptureMode.audioOnly.capturesCamera)
    }

    /// Video modes must not quietly acquire permissions for the audio path, and audio
    /// must not acquire any it did not already need. A mode that asks macOS for the
    /// camera in order to record a conversation is a privacy regression, not a feature.
    func test_audioOnlyAsksForNothingNew() {
        XCTAssertEqual(CaptureMode.audioOnly.requiredPermissions, [.microphone])
    }

    func test_eachModeAsksForExactlyWhatItUses() {
        XCTAssertEqual(CaptureMode.audioScreen.requiredPermissions, [.microphone, .screen])
        XCTAssertEqual(CaptureMode.audioCamera.requiredPermissions, [.microphone, .camera])
        XCTAssertEqual(CaptureMode.full.requiredPermissions, [.microphone, .screen, .camera])
    }

    /// The raw values are written into settings.json. Renaming one silently resets every
    /// existing user to the default, which is the one bug a stored enum reliably ships.
    func test_storedRawValuesAreStable() {
        XCTAssertEqual(CaptureMode.audioOnly.rawValue, "audio")
        XCTAssertEqual(CaptureMode.audioScreen.rawValue, "audioScreen")
        XCTAssertEqual(CaptureMode.audioCamera.rawValue, "audioCamera")
        XCTAssertEqual(CaptureMode.full.rawValue, "audioScreenCamera")
        XCTAssertEqual(PerformanceProfile.lowStorage.rawValue, "lowStorage")
        XCTAssertEqual(PerformanceProfile.balanced.rawValue, "balanced")
        XCTAssertEqual(PerformanceProfile.lowCPU.rawValue, "lowCPU")
    }

    /// Four one-word labels, because they sit in a segmented picker inside a 440-point
    /// pane and a wrapped segment reads as a broken control.
    func test_labelsFitTheSegmentedPicker() {
        XCTAssertEqual(CaptureMode.allCases.count, 4)
        for mode in CaptureMode.allCases {
            XCTAssertFalse(mode.label.contains(" "), "\(mode.rawValue) label wraps")
            XCTAssertLessThanOrEqual(mode.label.count, 7, "\(mode.rawValue) label")
            XCTAssertGreaterThan(mode.blurb.count, 20, "\(mode.rawValue) blurb")
            XCTAssertFalse(mode.symbol.isEmpty, "\(mode.rawValue) symbol")
        }
    }

    // MARK: - Codec selection

    /// The light profile exists to be cheap to encode and to play anywhere. HEVC is
    /// neither of those, so if this ever flips the profile has stopped meaning anything.
    func test_theLightProfileIsTheOneThatUsesH264() {
        XCTAssertEqual(PerformanceProfile.lowCPU.codec, .h264)
        XCTAssertEqual(PerformanceProfile.balanced.codec, .hevc)
        XCTAssertEqual(PerformanceProfile.lowStorage.codec, .hevc)
    }

    /// H.264 has to be assumed bulkier than HEVC at equal quality, or the size estimates
    /// derived from these numbers say the light profile is the small one.
    func test_h264IsBudgetedAsTheBiggerCodec() {
        XCTAssertGreaterThan(CaptureCodec.h264.bitsPerPixel, CaptureCodec.hevc.bitsPerPixel)
    }

    // MARK: - Frame geometry

    /// Odd dimensions are either rejected by the encoder or silently padded, and the
    /// padding is a green stripe down one side of every frame.
    func test_dimensionsAreAlwaysEven() {
        let awkward = [(1_001, 667), (1_365, 767), (3, 5), (2_559, 1_439)]
        for (w, h) in awkward {
            for edge in [640, 1_280, 1_920] {
                let fitted = CapturePlan.fit(width: w, height: h, longEdge: edge)
                XCTAssertEqual(fitted.width % 2, 0, "\(w)×\(h) → \(fitted)")
                XCTAssertEqual(fitted.height % 2, 0, "\(w)×\(h) → \(fitted)")
            }
        }
    }

    /// A 720p camera blown up to 1920 is the same picture at four times the bit rate.
    func test_smallSourcesAreNeverUpscaled() {
        let fitted = CapturePlan.fit(width: 640, height: 480, longEdge: 1_920)
        XCTAssertEqual(fitted.width, 640)
        XCTAssertEqual(fitted.height, 480)
    }

    func test_aspectRatioSurvivesTheScale() {
        let fitted = CapturePlan.fit(width: 3_840, height: 2_160, longEdge: 1_920)
        XCTAssertEqual(fitted.width, 1_920)
        XCTAssertEqual(fitted.height, 1_080)
    }

    /// Portrait and square displays exist. The long edge is the long edge, not the width.
    func test_theLongEdgeIsWhicheverEdgeIsLonger() {
        let portrait = CapturePlan.fit(width: 1_080, height: 3_840, longEdge: 1_920)
        XCTAssertEqual(portrait.height, 1_920)
        XCTAssertLessThan(portrait.width, portrait.height)
    }

    func test_zeroSizedSourcesDoNotProduceAZeroDivide() {
        XCTAssertEqual(CapturePlan.fit(width: 0, height: 0, longEdge: 1_920).width, 0)
        XCTAssertEqual(CapturePlan.fit(width: 100, height: 100, longEdge: 0).width, 0)
    }

    // MARK: - Bit rate

    func test_audioOnlyPlansHaveNoVideoAtAll() {
        let plan = CapturePlan.make(mode: .audioOnly, profile: .balanced,
                                    screen: (3_840, 2_160), camera: (1_280, 720))
        XCTAssertEqual(plan.videoBitRate, 0)
        XCTAssertEqual(plan.width, 0)
        XCTAssertEqual(plan.frameRate, 0)
    }

    /// The guard that stops a 6K display from asking for a forty-megabit stream, and the
    /// one that stops a tiny frame from being encoded into porridge.
    func test_bitRateIsClamped() {
        let huge = CapturePlan.make(mode: .full, profile: .balanced, screen: (6_016, 3_384))
        XCTAssertLessThanOrEqual(huge.videoBitRate, CapturePlan.maximumBitRate)

        let tiny = CapturePlan.make(mode: .audioCamera, profile: .lowStorage, camera: (160, 120))
        XCTAssertGreaterThanOrEqual(tiny.videoBitRate, CapturePlan.minimumBitRate)
    }

    /// The whole point of the Small profile. If this ordering ever breaks, the picker is
    /// offering three names for the same file size.
    func test_theProfilesAreActuallyOrderedBySize() {
        let screen = (2_560, 1_440)
        let small = CapturePlan.make(mode: .audioScreen, profile: .lowStorage, screen: screen)
        let balanced = CapturePlan.make(mode: .audioScreen, profile: .balanced, screen: screen)
        let light = CapturePlan.make(mode: .audioScreen, profile: .lowCPU, screen: screen)

        XCTAssertLessThan(small.videoBitRate, balanced.videoBitRate)
        // Light is H.264 at a smaller frame — the codec penalty is what makes it the
        // biggest of the three, and that is the trade the label promises.
        XCTAssertGreaterThan(light.videoBitRate, balanced.videoBitRate)
    }

    /// Compositing the camera into the corner adds detail to a region that was static
    /// desktop. Not free, and the estimate must not pretend it is.
    func test_theCompositedInsetCostsSomething() {
        let screenOnly = CapturePlan.make(mode: .audioScreen, profile: .balanced, screen: (1_920, 1_080))
        let both = CapturePlan.make(mode: .full, profile: .balanced,
                                    screen: (1_920, 1_080), camera: (1_280, 720))
        XCTAssertEqual(both.width, screenOnly.width, "the movie is the size of the screen track")
        XCTAssertGreaterThan(both.videoBitRate, screenOnly.videoBitRate)
    }

    /// The Settings pane asks for an estimate before any display has been resolved. It
    /// must get a real number rather than a zero that reads as "this costs nothing".
    func test_aPlanWithNoSourceYetIsStillAnEstimate() {
        let plan = CapturePlan.make(mode: .audioScreen, profile: .balanced)
        XCTAssertGreaterThan(plan.videoBitRate, 0)
        XCTAssertGreaterThan(plan.width, 0)
        XCTAssertEqual(plan.width % 2, 0)
    }

    func test_summaryNamesTheThingsThatDecideTheSize() {
        let plan = CapturePlan.make(mode: .audioScreen, profile: .balanced, screen: (1_920, 1_080))
        XCTAssertEqual(plan.summary, "1920 × 1080 · 24 fps · HEVC")
        XCTAssertEqual(CapturePlan.make(mode: .audioOnly, profile: .balanced).summary, "24 kHz mono WAV")
    }
}
