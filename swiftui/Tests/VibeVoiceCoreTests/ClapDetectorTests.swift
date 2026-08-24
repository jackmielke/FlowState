import XCTest
@testable import VibeVoiceCore

final class ClapDetectorTests: XCTestCase {

    /// 20 ms frames, like the audio tap delivers.
    private let frame = 0.02

    /// Feeds a stretch of room noise, then returns the time it ended at.
    private func quiet(_ d: ClapDetector, seconds: Double, from t: Double,
                       level: Float = 0.02) -> (ClapDetector, Double) {
        var d = d, t = t
        while t < seconds { _ = d.feed(peak: level, at: t); t += frame }
        return (d, t)
    }

    /// One frame loud, then quiet — the shape of a clap.
    private func clap(_ d: inout ClapDetector, at t: Double, level: Float = 0.8) -> Bool {
        var fired = d.feed(peak: level, at: t)
        if d.feed(peak: 0.02, at: t + frame) { fired = true }
        return fired
    }

    func testTwoClapsWake() {
        var d = ClapDetector()
        (d, _) = quiet(d, seconds: 2, from: 0)
        XCTAssertFalse(clap(&d, at: 2.0), "the first clap must not fire")
        XCTAssertTrue(clap(&d, at: 2.3), "the second clap should wake it")
    }

    /// The whole reason it takes two: one loud noise is a door, a mug, a lid.
    func testOneClapDoesNothing() {
        var d = ClapDetector()
        (d, _) = quiet(d, seconds: 2, from: 0)
        XCTAssertFalse(clap(&d, at: 2.0))
        var t = 2.04
        while t < 6 { XCTAssertFalse(d.feed(peak: 0.02, at: t)); t += frame }
    }

    /// Too fast is one clap echoing; too slow is two unrelated noises.
    func testTheGapHasToBeRight() {
        var fast = ClapDetector()
        (fast, _) = quiet(fast, seconds: 2, from: 0)
        _ = clap(&fast, at: 2.0)
        XCTAssertFalse(clap(&fast, at: 2.05), "50 ms apart is one clap, twice")

        var slow = ClapDetector()
        (slow, _) = quiet(slow, seconds: 2, from: 0)
        _ = clap(&slow, at: 2.0)
        XCTAssertFalse(clap(&slow, at: 4.0), "two seconds apart is not a double clap")
    }

    /// Speech is loud but not sharp. Sustained energy must never read as a clap.
    func testSpeechDoesNotWakeIt() {
        var d = ClapDetector()
        (d, _) = quiet(d, seconds: 2, from: 0)
        // Two half-second bursts, the cadence of two spoken words.
        for start in [2.0, 2.8] {
            var t = start
            while t < start + 0.5 {
                XCTAssertFalse(d.feed(peak: 0.35, at: t), "speech woke it at \(t)")
                t += frame
            }
            _ = d.feed(peak: 0.02, at: t)
        }
    }

    /// A silent room makes every ratio enormous, so the absolute floor is what stops two
    /// keyboard taps from waking it.
    func testQuietTapsInASilentRoomAreNotClaps() {
        var d = ClapDetector()
        (d, _) = quiet(d, seconds: 2, from: 0, level: 0.002)
        _ = clap(&d, at: 2.0, level: 0.05)
        XCTAssertFalse(clap(&d, at: 2.3, level: 0.05))
    }

    /// Demonstrating it usually means clapping more than twice.
    func testDoesNotRefireOnApplause() {
        var d = ClapDetector()
        (d, _) = quiet(d, seconds: 2, from: 0)
        _ = clap(&d, at: 2.0)
        XCTAssertTrue(clap(&d, at: 2.3))
        XCTAssertFalse(clap(&d, at: 2.6), "still in the cooldown")
        XCTAssertFalse(clap(&d, at: 2.9))
    }

    /// Three claps still contain a valid pair — the middle one should not be wasted.
    func testThreeClapsStillWake() {
        var d = ClapDetector()
        (d, _) = quiet(d, seconds: 2, from: 0)
        _ = clap(&d, at: 2.0)
        XCTAssertTrue(clap(&d, at: 2.25))
    }
}
