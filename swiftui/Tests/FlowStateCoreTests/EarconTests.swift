import XCTest
@testable import FlowStateCore

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

    // MARK: - WAV encoding

    /// The dictation sounds play through AVAudioPlayer rather than the shared engine, so
    /// a malformed header is the difference between a chime and silence — and silence is
    /// indistinguishable from "the hotkey did not fire", which is the bug you would
    /// actually go looking for.
    func test_wavHeaderIsWellFormed() {
        let data = Earcon.dictateOpen.wavData(sampleRate: 44_100)
        XCTAssertGreaterThan(data.count, 44, "header plus at least some audio")

        func ascii(_ range: Range<Int>) -> String {
            String(decoding: data[range], as: UTF8.self)
        }
        func u32(_ offset: Int) -> UInt32 {
            data[offset..<offset + 4].reduce(into: UInt32(0)) { acc, byte in acc = acc | UInt32(byte) }
        }

        XCTAssertEqual(ascii(0..<4), "RIFF")
        XCTAssertEqual(ascii(8..<12), "WAVE")
        XCTAssertEqual(ascii(12..<16), "fmt ")
        XCTAssertEqual(ascii(36..<40), "data")

        // The two length fields have to agree with the actual byte count, or players
        // truncate or read past the end.
        let declaredRIFF = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        XCTAssertEqual(Int(UInt32(littleEndian: declaredRIFF)), data.count - 8)

        let declaredData = data.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt32.self) }
        XCTAssertEqual(Int(UInt32(littleEndian: declaredData)), data.count - 44)
    }

    /// 16-bit mono at the rate we asked for. A stereo or 8-bit header would still play,
    /// just at the wrong speed or pitch, which is a confusing thing to debug by ear.
    func test_wavFormatIsSixteenBitMono() {
        let data = Earcon.dictateClose.wavData(sampleRate: 22_050)
        let channels = data.withUnsafeBytes { $0.load(fromByteOffset: 22, as: UInt16.self) }
        let rate = data.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self) }
        let bits = data.withUnsafeBytes { $0.load(fromByteOffset: 34, as: UInt16.self) }
        XCTAssertEqual(UInt16(littleEndian: channels), 1)
        XCTAssertEqual(UInt32(littleEndian: rate), 22_050)
        XCTAssertEqual(UInt16(littleEndian: bits), 16)
    }

    /// The dictation pair fires dozens of times a minute. If either is ever as loud as the
    /// sounds that mark once-an-hour events, it stops being feedback and becomes a tic.
    func test_dictationEarconsAreQuieterThanEverythingElse() {
        for e in [Earcon.dictateOpen, .dictateClose] {
            XCTAssertLessThan(e.level, Earcon.heard.level, "quieter than the quietest of the others")
            XCTAssertLessThan(e.duration, Earcon.heard.duration, "and shorter")
        }
    }
}
