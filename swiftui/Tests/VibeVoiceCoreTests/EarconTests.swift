import XCTest
@testable import VibeVoiceCore

final class EarconTests: XCTestCase {

    private let rate = 24_000.0

    func testRendersTheExpectedLength() {
        let s = Earcon.wake.render(sampleRate: rate)
        XCTAssertEqual(Double(s.count) / rate, Earcon.wake.duration, accuracy: 0.002)
    }

    /// The whole reason for the envelope: a step from silence is a click, and a click is
    /// the difference between a designed sound and a fault.
    func testStartsAndEndsAtSilence() {
        for e in [Earcon.wake, .sleep, .heard, .trouble] {
            let s = e.render(sampleRate: rate)
            XCTAssertEqual(s.first ?? 1, 0, accuracy: 0.001)
            XCTAssertEqual(s.last ?? 1, 0, accuracy: 0.02)
        }
    }

    /// And no step anywhere in the middle either — including across the note boundary,
    /// which is where a naive two-note tone clicks.
    ///
    /// Measured against the waveform's own steepest legal slope rather than a constant.
    /// A sine's largest one-sample step is `2π·f/rate · level`, which for the top note
    /// here is about 0.037 — a fixed threshold below that fails on a perfectly clean
    /// tone, which is how the first version of this test failed.
    func testHasNoDiscontinuities() {
        for e in [Earcon.wake, .sleep, .trouble] {
            let s = e.render(sampleRate: rate)
            let steepest = 2 * Double.pi * (e.notes.max() ?? 0) / rate * e.level
            var worst: Float = 0
            for i in 1..<s.count { worst = max(worst, abs(s[i] - s[i - 1])) }
            XCTAssertLessThan(Double(worst), steepest * 1.2,
                              "a step beyond the waveform's own slope is a click")
        }
    }

    func testStaysWithinItsLevel() {
        for e in [Earcon.wake, .sleep, .heard, .trouble] {
            let peak = e.render(sampleRate: rate).map(abs).max() ?? 0
            XCTAssertLessThanOrEqual(peak, Float(e.level) + 0.001)
            XCTAssertGreaterThan(peak, Float(e.level) * 0.8, "the envelope should not swallow it")
        }
    }

    /// Arriving and leaving are the same interval in opposite directions. If somebody
    /// retunes one, this says the pair no longer means anything.
    func testSleepIsWakeBackwards() {
        XCTAssertEqual(Earcon.wake.notes, Earcon.sleep.notes.reversed())
    }

    /// These play while somebody is listening for a reply, so they have to be short.
    func testTheyAreAllShort() {
        for e in [Earcon.wake, .sleep, .heard, .trouble] {
            XCTAssertLessThan(e.duration, 0.3)
        }
    }

    func testSurvivesSillyInputs() {
        XCTAssertTrue(Earcon(notes: []).render(sampleRate: rate).isEmpty)
        XCTAssertTrue(Earcon.wake.render(sampleRate: 0).isEmpty)
        XCTAssertTrue(Earcon(notes: [440], noteLength: 0.00001).render(sampleRate: rate).isEmpty)
    }
}
