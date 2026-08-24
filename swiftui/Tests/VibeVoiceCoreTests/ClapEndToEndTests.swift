import XCTest
@testable import VibeVoiceCore

/// The detector fed the way the app actually feeds it: 10 ms sub-frames, from a
/// sample-derived clock, with peaks shaped like a real clap — a near-instant attack and
/// an exponential tail — rather than one loud frame surrounded by silence.
///
/// This exists because the unit tests all passed while the feature did not work. They
/// fed idealised frames; the app fed 43 ms chunks of the hardware buffer, so a clap
/// landing across two of them measured 85 ms and was rejected for being too long. A test
/// at the real granularity is the one that would have caught it.
final class ClapEndToEndTests: XCTestCase {

    private let sub = 0.01

    /// A clap's envelope: an instant attack and an exponential tail over 60 ms.
    ///
    /// The peak handed to the detector is the MAXIMUM of the envelope across each 10 ms
    /// window, not a single point sampled at the window's start — because that is what
    /// the real code does, taking the loudest of 240 samples. Sampling one point instead
    /// made the harness miss a clap's peak whenever it fell between two window boundaries, and
    /// the resulting failure looked exactly like a detector bug.
    private func envelope(_ t: TimeInterval, claps: [TimeInterval], level: Float, room: Float) -> Float {
        var peak = room
        for c in claps where t >= c && t < c + 0.06 {
            peak = max(peak, level * exp(-9 * Float((t - c) / 0.06)))
        }
        return peak
    }

    private func feed(_ d: inout ClapDetector,
                      claps: [TimeInterval],
                      level: Float,
                      room: Float = 0.02,
                      until: TimeInterval = 4) -> [ClapEvent] {
        var events: [ClapEvent] = []
        var frame = 0
        while Double(frame) * sub < until {
            let start = Double(frame) * sub
            // 1 ms steps across the window; the real code sees every sample.
            var peak = room
            for k in 0..<10 {
                peak = max(peak, envelope(start + Double(k) * 0.001,
                                          claps: claps, level: level, room: room))
            }
            events.append(d.feed(peak: peak, at: start))
            frame += 1
        }
        return events
    }

    private func woke(_ events: [ClapEvent]) -> Bool {
        events.contains { if case .wake = $0 { return true }; return false }
    }

    func testARealisticDoubleClapWakesIt() {
        var d = ClapDetector(sensitivity: 0.35)
        XCTAssertTrue(woke(feed(&d, claps: [1.5, 1.8], level: 0.7)))
    }

    /// Across the range a person's claps might land at, once calibrated.
    func testWorksAtEveryLevelTheDialCovers() {
        for level in [Float(0.12), 0.25, 0.5, 0.9] {
            let sensitivity = ClapCalibration.recommend(
                claps: [.init(at: 0, peak: level), .init(at: 0.3, peak: level * 0.95)],
                room: 0.02)
            var d = ClapDetector(sensitivity: sensitivity)
            XCTAssertTrue(woke(feed(&d, claps: [1.5, 1.8], level: level)),
                          "a \(level) clap failed at the calibrated sensitivity \(sensitivity)")
        }
    }

    /// The gap a person actually leaves, which is not always a tidy 300 ms.
    func testToleratesTheGapsPeopleActuallyLeave() {
        for gap in [0.15, 0.22, 0.3, 0.45, 0.6] {
            var d = ClapDetector(sensitivity: 0.35)
            XCTAssertTrue(woke(feed(&d, claps: [1.5, 1.5 + gap], level: 0.7)),
                          "a \(gap)s gap should count")
        }
    }

    /// And still refuses the things it refused before.
    func testStillIgnoresSpeechAndSingleNoises() {
        var one = ClapDetector(sensitivity: 0.35)
        XCTAssertFalse(woke(feed(&one, claps: [1.5], level: 0.7)))

        var speech = ClapDetector(sensitivity: 0.35)
        var events: [ClapEvent] = []
        var t = 0.0
        while t < 4 {
            // Syllables: loud for 150 ms at a time, which is far longer than a clap.
            let talking = Int(t / 0.15) % 2 == 0 && t > 1
            events.append(speech.feed(peak: talking ? 0.42 : 0.05, at: t))
            t += sub
        }
        XCTAssertFalse(woke(events), "speech woke it")
    }
}

