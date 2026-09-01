import XCTest
@testable import FlowStateCore

final class ClapDetectorTests: XCTestCase {

    /// 20 ms frames, like the audio tap delivers.
    private let frame = 0.02

    private func room(_ d: inout ClapDetector, until: Double, from: Double,
                      level: Float = 0.02) -> Double {
        var t = from
        while t < until { _ = d.feed(peak: level, at: t); t += frame }
        return t
    }

    /// One loud frame, then silence — the shape of a clap.
    @discardableResult
    private func clap(_ d: inout ClapDetector, at t: Double, level: Float = 0.8) -> ClapEvent {
        _ = d.feed(peak: level, at: t)
        return d.feed(peak: 0.01, at: t + frame)
    }

    private func isWake(_ e: ClapEvent) -> Bool {
        if case .wake = e { return true }
        return false
    }

    func testTwoClapsWake() {
        var d = ClapDetector()
        _ = room(&d, until: 2, from: 0)
        XCTAssertFalse(isWake(clap(&d, at: 2.0)), "the first must not fire")
        XCTAssertTrue(isWake(clap(&d, at: 2.3)), "the second should")
    }

    /// The whole reason it takes two.
    func testOneClapDoesNothing() {
        var d = ClapDetector()
        _ = room(&d, until: 2, from: 0)
        clap(&d, at: 2.0)
        var t = 2.06
        while t < 6 {
            XCTAssertFalse(isWake(d.feed(peak: 0.02, at: t)))
            t += frame
        }
    }

    /// The rule that does the most work: a clap inside speech is a syllable.
    func testAClapInsideSpeechIsRejected() {
        var d = ClapDetector()
        _ = room(&d, until: 2, from: 0)
        clap(&d, at: 2.0)
        // Talking, then a breath too short to count as quiet, then the second clap.
        // The breath matters: without it the speech and the clap merge into one long
        // loud run and are rejected for being long, which is the right answer by the
        // wrong rule and would leave this rule untested.
        var t = 2.1
        while t < 2.4 { _ = d.feed(peak: 0.3, at: t); t += frame }
        _ = d.feed(peak: 0.01, at: 2.40)
        _ = d.feed(peak: 0.01, at: 2.42)
        let e = clap(&d, at: 2.46)
        XCTAssertFalse(isWake(e))
        guard case .rejected(let why, _) = e else { return XCTFail("expected a reason, got \(e)") }
        XCTAssertEqual(why, "came in the middle of other sound")
    }

    /// Sustained energy is a voice, not a clap.
    func testSpeechDoesNotWakeIt() {
        var d = ClapDetector()
        _ = room(&d, until: 2, from: 0)
        for start in [2.0, 2.8] {
            var t = start
            while t < start + 0.5 {
                XCTAssertFalse(isWake(d.feed(peak: 0.35, at: t)), "speech woke it at \(t)")
                t += frame
            }
            _ = d.feed(peak: 0.02, at: t)
        }
    }

    /// A silent room makes every ratio enormous; the absolute floor is what stops two
    /// keyboard taps.
    func testQuietTapsInASilentRoomAreNotClaps() {
        var d = ClapDetector()
        _ = room(&d, until: 2, from: 0, level: 0.002)
        clap(&d, at: 2.0, level: 0.06)
        XCTAssertFalse(isWake(clap(&d, at: 2.3, level: 0.06)))
    }

    /// A door then a cough is not two claps.
    func testAMismatchedPairIsRejected() {
        var d = ClapDetector()
        _ = room(&d, until: 2, from: 0)
        clap(&d, at: 2.0, level: 0.95)
        let e = clap(&d, at: 2.3, level: 0.14)
        XCTAssertFalse(isWake(e))
    }

    func testGapBoundsHold() {
        var fast = ClapDetector()
        _ = room(&fast, until: 2, from: 0)
        clap(&fast, at: 2.0)
        XCTAssertFalse(isWake(clap(&fast, at: 2.04)), "one clap echoing")

        var slow = ClapDetector()
        _ = room(&slow, until: 2, from: 0)
        clap(&slow, at: 2.0)
        XCTAssertFalse(isWake(clap(&slow, at: 4.0)), "two unrelated noises")
    }

    func testDoesNotRefireOnApplause() {
        var d = ClapDetector()
        _ = room(&d, until: 2, from: 0)
        clap(&d, at: 2.0)
        XCTAssertTrue(isWake(clap(&d, at: 2.3)))
        XCTAssertFalse(isWake(clap(&d, at: 2.7)))
        XCTAssertFalse(isWake(clap(&d, at: 3.1)))
    }

    /// The dial has to actually move the thresholds, in the direction the label claims.
    func testSensitivityIsMonotonic() {
        let low = ClapDetector(sensitivity: 0)
        let high = ClapDetector(sensitivity: 1)
        XCTAssertGreaterThan(low.attackRatio, high.attackRatio)
        XCTAssertGreaterThan(low.floor, high.floor)
        XCTAssertGreaterThan(low.quietBefore, high.quietBefore)
    }

    /// At its least sensitive, the clap that works at the default must not.
    func testTurningItDownActuallyRefuses() {
        var d = ClapDetector(sensitivity: 0)
        _ = room(&d, until: 2, from: 0)
        clap(&d, at: 2.0, level: 0.2)
        XCTAssertFalse(isWake(clap(&d, at: 2.3, level: 0.2)))
    }

    /// Every rejection has to say something a person can act on.
    func testRejectionsExplainThemselves() {
        var d = ClapDetector()
        _ = room(&d, until: 2, from: 0)
        var t = 2.0
        while t < 2.5 { _ = d.feed(peak: 0.9, at: t); t += frame }   // far too long
        let e = d.feed(peak: 0.01, at: t)
        guard case .rejected(let why, _) = e else { return XCTFail("expected a rejection") }
        XCTAssertFalse(why.isEmpty)
    }
}
