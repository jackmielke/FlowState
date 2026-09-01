import XCTest
@testable import FlowStateCore

/// What a recording costs in disk, and when that is worth saying out loud.
///
/// The failure this exists to prevent is not a bad file. It is a full startup disk two
/// hours into a session, which takes the rest of the Mac down with it — so the interesting
/// cases here are all about *when* the warning fires: never for audio, not for the default
/// video profile on a healthy disk, and unmistakably when an hour of recording would not
/// fit in the space that is left.
final class CaptureStorageTests: XCTestCase {

    private let terabyte = 1_000_000_000_000
    private let screen = (width: 2_560, height: 1_440)

    private func plan(_ mode: CaptureMode, _ profile: PerformanceProfile) -> CapturePlan {
        CapturePlan.make(mode: mode, profile: profile, screen: screen, camera: (1_280, 720))
    }

    // MARK: - The rate itself

    /// 24 kHz × 16-bit × mono is 48 kB a second, and that is not an estimate — it is what
    /// `SessionRecorder` writes, byte for byte, plus a 44-byte header.
    func test_audioRateIsTheRateTheRecorderActuallyWrites() {
        let audio = CapturePlan.make(mode: .audioOnly, profile: .balanced)
        XCTAssertEqual(CaptureStorage.bytesPerSecond(for: audio), 48_000)
        // An hour of conversation is 170 MB. This is why audio never needed a warning.
        XCTAssertEqual(CaptureStorage.bytes(for: audio, seconds: 3_600), 172_800_000)
    }

    /// Every video mode must cost more than audio, or the whole warning apparatus is
    /// pointed at the wrong thing.
    func test_everyVideoModeCostsMoreThanAudio() {
        let audioRate = CaptureStorage.bytesPerSecond(for: CapturePlan.make(mode: .audioOnly, profile: .balanced))
        for mode in CaptureMode.allCases where mode.isVideo {
            for profile in PerformanceProfile.allCases {
                XCTAssertGreaterThan(CaptureStorage.bytesPerSecond(for: plan(mode, profile)), audioRate,
                                     "\(mode.rawValue)/\(profile.rawValue)")
            }
        }
    }

    /// The Small profile has to be *substantially* smaller or it is not worth being a
    /// separate choice. Measured, not asserted in a comment: a fifth is what the label
    /// claims.
    func test_theSmallProfileIsAboutAFifthOfBalanced() {
        let small = CaptureStorage.bytesPerSecond(for: plan(.audioScreen, .lowStorage))
        let balanced = CaptureStorage.bytesPerSecond(for: plan(.audioScreen, .balanced))
        let ratio = Double(small) / Double(balanced)
        XCTAssertLessThan(ratio, 0.30, "Small is \(Int(ratio * 100))% of Balanced")
    }

    func test_rateLabelGivesBothTheMinuteAndTheHour() {
        let label = CaptureStorage.rateLabel(for: plan(.audioScreen, .balanced))
        XCTAssertTrue(label.contains("a minute"), label)
        XCTAssertTrue(label.contains("an hour"), label)
        // Estimates are marked as estimates. A number quoted flat reads as a measurement.
        XCTAssertTrue(label.hasPrefix("≈"), label)
    }

    // MARK: - Before the button is pressed

    func test_audioOnAHealthyDiskNeverWarns() {
        let advice = CaptureStorage.advice(for: CapturePlan.make(mode: .audioOnly, profile: .balanced),
                                           freeBytes: terabyte)
        XCTAssertEqual(advice.level, .ok)
        XCTAssertFalse(advice.isWarning)
    }

    /// The default video setup on a normal Mac. If this warns, every recording warns, and
    /// a warning that is always on is furniture.
    func test_theDefaultVideoProfileOnAHealthyDiskDoesNotWarn() {
        let advice = CaptureStorage.advice(for: plan(.audioScreen, .balanced), freeBytes: 500_000_000_000)
        XCTAssertEqual(advice.level, .ok, advice.detail)
    }

    /// …but the heavy end of the range says so, even with a terabyte free, because "you
    /// will not run out of space" and "this file will be enormous" are different facts.
    func test_theHeaviestSetupIsCalledLargeEvenOnAHugeDisk() {
        let advice = CaptureStorage.advice(for: plan(.full, .lowCPU), freeBytes: terabyte)
        XCTAssertEqual(advice.level, .caution, advice.detail)
        XCTAssertTrue(advice.detail.contains("Small"), "the way out should be named: \(advice.detail)")
    }

    func test_aDiskWithNoRoomLeftIsCritical() {
        // 400 MB free: Balanced writes about 1.6 GB an hour, so this cannot last.
        let advice = CaptureStorage.advice(for: plan(.audioScreen, .balanced), freeBytes: 400_000_000)
        XCTAssertEqual(advice.level, .critical, advice.detail)
        // And it names the way out rather than just the problem.
        XCTAssertTrue(advice.detail.contains("audio only"), advice.detail)
    }

    /// Below two gigabytes macOS itself starts failing — this is not a polite warning.
    func test_anAlreadyFullDiskIsCriticalEvenForAudio() {
        let advice = CaptureStorage.advice(for: CapturePlan.make(mode: .audioOnly, profile: .balanced),
                                           freeBytes: 900_000_000)
        XCTAssertEqual(advice.level, .critical, advice.detail)
    }

    /// An hour planning to eat a third of what is free is a real risk on a long session.
    func test_takingALargeShareOfWhatIsFreeIsACaution() {
        // Balanced ≈1.6 GB/hour; 5 GB free is about a third of it.
        let advice = CaptureStorage.advice(for: plan(.audioScreen, .balanced), freeBytes: 5_000_000_000)
        XCTAssertEqual(advice.level, .caution, advice.detail)
        XCTAssertTrue(advice.detail.contains("free"), advice.detail)
    }

    /// A volume that would not report its free space must not be treated as an empty one.
    /// Inventing a warning about a number we could not read is how warnings stop being
    /// believed.
    func test_unknownFreeSpaceDoesNotManufactureAWarning() {
        XCTAssertEqual(CaptureStorage.advice(for: plan(.audioScreen, .balanced), freeBytes: 0).level, .ok)
        XCTAssertEqual(CaptureStorage.advice(for: CapturePlan.make(mode: .audioOnly, profile: .balanced),
                                             freeBytes: 0).level, .ok)
    }

    /// Whatever it says, it always says how big this is. That is the number the user
    /// actually needs, warning or not.
    func test_everyAdviceQuotesTheRate() {
        for mode in CaptureMode.allCases {
            for profile in PerformanceProfile.allCases {
                for free in [0, 900_000_000, 5_000_000_000, terabyte] {
                    let advice = CaptureStorage.advice(for: plan(mode, profile), freeBytes: free)
                    XCTAssertFalse(advice.detail.isEmpty)
                    XCTAssertFalse(advice.headline.isEmpty)
                    XCTAssertTrue(advice.detail.hasSuffix("."), advice.detail)
                }
            }
        }
    }

    // MARK: - While it is running

    func test_aFewSecondsInSaysNothingAlarming() {
        let advice = CaptureStorage.liveAdvice(for: plan(.audioScreen, .balanced),
                                               bytesWritten: 12_000_000, freeBytes: terabyte)
        XCTAssertEqual(advice.level, .ok)
        XCTAssertTrue(advice.headline.contains("MB"), advice.headline)
    }

    /// Under five minutes of headroom is an emergency: it is less time than it takes to
    /// notice a banner and go delete something.
    func test_minutesFromFullIsCritical() {
        let p = plan(.audioScreen, .balanced)
        let twoMinutes = CaptureStorage.bytesPerSecond(for: p) * 120
        let advice = CaptureStorage.liveAdvice(for: p, bytesWritten: 3_000_000_000, freeBytes: twoMinutes)
        XCTAssertEqual(advice.level, .critical, advice.detail)
        XCTAssertTrue(advice.headline.lowercased().contains("stop"), advice.headline)
    }

    /// The last threshold that a real disk can sit at: below it the 2 GB floor takes
    /// over and the advice is critical rather than a heads-up.
    func test_anHourAndAHalfFromFullIsACaution() {
        let p = plan(.audioScreen, .balanced)
        let ninetyMinutes = CaptureStorage.bytesPerSecond(for: p) * 5_400
        XCTAssertGreaterThan(ninetyMinutes, CaptureStorage.criticalFreeBytes, "otherwise the floor fires first")
        let advice = CaptureStorage.liveAdvice(for: p, bytesWritten: 1_000_000, freeBytes: ninetyMinutes)
        XCTAssertEqual(advice.level, .caution, advice.detail)
    }

    /// A gigabyte on disk is worth mentioning on its own — you are past the point where
    /// this is a file you keep without thinking about it.
    func test_aGigabyteWrittenIsMentionedEvenWithRoomToSpare() {
        let advice = CaptureStorage.liveAdvice(for: plan(.audioScreen, .balanced),
                                               bytesWritten: 1_400_000_000, freeBytes: terabyte)
        XCTAssertEqual(advice.level, .caution, advice.detail)
        XCTAssertTrue(advice.headline.contains("GB"), advice.headline)
    }

    // MARK: - Projections

    /// Coarse on purpose: this is a projection from an average bit rate, and a projection
    /// quoted to the second reads as a measurement.
    func test_durationLabelStaysCoarse() {
        XCTAssertEqual(CaptureStorage.durationLabel(30), "30 seconds")
        XCTAssertEqual(CaptureStorage.durationLabel(600), "10 minutes")
        XCTAssertEqual(CaptureStorage.durationLabel(7_200), "2.0 hours")
        XCTAssertEqual(CaptureStorage.durationLabel(-5), "0 seconds")
    }

    func test_remainingTimeIsUnknownRatherThanZeroWhenTheDiskIsUnreadable() {
        XCTAssertNil(CaptureStorage.secondsRemaining(for: plan(.audioScreen, .balanced), freeBytes: 0))
        let left = CaptureStorage.secondsRemaining(for: plan(.audioScreen, .balanced), freeBytes: terabyte)
        XCTAssertNotNil(left)
        XCTAssertGreaterThan(left ?? 0, 3_600)
    }
}
