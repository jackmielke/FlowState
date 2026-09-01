import XCTest
@testable import FlowStateCore

final class ClapCalibrationTests: XCTestCase {

    /// A recording: quiet room, with claps dropped into it.
    private func recording(claps at: [TimeInterval], level: Float, room: Float = 0.02)
        -> [ClapCalibration.Sample] {
        var out: [ClapCalibration.Sample] = []
        var t = 0.0
        while t < 6 {
            let isClap = at.contains { abs(t - $0) < 0.005 }
            out.append(.init(at: t, peak: isClap ? level : room))
            t += 0.01
        }
        return out
    }

    func testFindsTheClaps() {
        let r = ClapCalibration.analyse(recording(claps: [1.0, 1.3, 2.0, 2.28], level: 0.7))
        XCTAssertEqual(r.claps.count, 4)
        XCTAssertTrue(r.isUsable)
    }

    /// A clap smeared across neighbouring samples is one clap, not three.
    func testOneClapCountsOnce() {
        var s = recording(claps: [], level: 0, room: 0.02)
        for i in 100..<105 { s[i] = .init(at: s[i].at, peak: 0.8) }
        XCTAssertEqual(ClapCalibration.claps(in: s, room: 0.02).count, 1)
    }

    /// The room is measured from the quiet part, not the average — a short recording is
    /// a quarter clapping, and a mean would be dragged up by it.
    func testRoomIsTheQuietPart() {
        let r = ClapCalibration.roomLevel(in: recording(claps: [1, 1.3, 2, 2.3], level: 0.9))
        XCTAssertEqual(r, 0.02, accuracy: 0.005)
    }

    /// Quiet claps need a more sensitive setting than loud ones. If this inverts, the
    /// whole calibration is backwards.
    func testQuieterClapsAskForMoreSensitivity() {
        let loud = ClapCalibration.recommend(
            claps: [.init(at: 0, peak: 0.8), .init(at: 0.3, peak: 0.75)], room: 0.02)
        let quiet = ClapCalibration.recommend(
            claps: [.init(at: 0, peak: 0.15), .init(at: 0.3, peak: 0.14)], room: 0.02)
        XCTAssertGreaterThan(quiet, loud)
    }

    /// The recommendation has to actually admit the claps it was given — the point of
    /// measuring is that afterwards they work.
    func testTheRecommendedSettingAcceptsThoseClaps() {
        for level in [Float(0.12), 0.3, 0.6, 0.95] {
            let samples = recording(claps: [1.0, 1.3], level: level)
            let r = ClapCalibration.analyse(samples)
            var d = ClapDetector(sensitivity: r.sensitivity)
            XCTAssertLessThan(d.floor, level,
                              "a \(level) clap must clear the floor at sensitivity \(r.sensitivity)")
            XCTAssertLessThan(d.threshold, level, "and the live threshold too")
        }
    }

    func testStaysInRange() {
        for level in [Float(0.01), 0.05, 0.5, 1.0] {
            let s = ClapCalibration.recommend(
                claps: [.init(at: 0, peak: level)], room: 0.02)
            XCTAssertTrue((0...1).contains(s), "\(s) out of range for \(level)")
        }
    }

    func testSaysSomethingUsefulWhenItHeardNothing() {
        let r = ClapCalibration.analyse(recording(claps: [], level: 0))
        XCTAssertFalse(r.isUsable)
        XCTAssertTrue(r.advice.contains("didn't hear"), r.advice)
    }

    func testSaysSomethingUsefulWhenItHeardOne() {
        let r = ClapCalibration.analyse(recording(claps: [1.0], level: 0.7))
        XCTAssertFalse(r.isUsable)
        XCTAssertTrue(r.advice.contains("only caught one"), r.advice)
    }
}
