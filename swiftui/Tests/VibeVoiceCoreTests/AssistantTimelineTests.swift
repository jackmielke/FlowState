import XCTest
@testable import VibeVoiceCore

final class AssistantTimelineTests: XCTestCase {

    /// The bug this type exists for: a whole reply arrives in one burst while the mic
    /// head has barely moved, and every chunk used to be written at that same head.
    func testBurstIsLaidOutEndToEndNotStacked() {
        var t = AssistantTimeline()
        let mic = 1_200                       // the mic has moved 50 ms at 24 kHz
        let offsets = (0..<8).map { _ in t.reserve(count: 2_400, micHead: mic) }
        XCTAssertEqual(offsets, [1_200, 3_600, 6_000, 8_400, 10_800, 13_200, 15_600, 18_000])
        XCTAssertEqual(Set(offsets).count, offsets.count, "chunks must not share an index")
    }

    /// A later turn starts when it is spoken, not immediately after the previous one —
    /// otherwise every silence between replies is squeezed out of the recording.
    func testNewTurnResyncsToTheMicHead() {
        var t = AssistantTimeline()
        _ = t.reserve(count: 24_000, micHead: 0)          // one second of speech
        XCTAssertEqual(t.head, 24_000)
        // Thirty seconds of silence pass; the mic head is the clock.
        XCTAssertEqual(t.reserve(count: 2_400, micHead: 720_000), 720_000)
    }

    /// Within a turn the assistant stays ahead of the mic and must not be dragged back.
    func testStaysAheadOfTheMicWithinATurn() {
        var t = AssistantTimeline()
        _ = t.reserve(count: 48_000, micHead: 0)
        XCTAssertEqual(t.reserve(count: 2_400, micHead: 12_000), 48_000)
    }

    func testResetClearsTheHeadBetweenTakes() {
        var t = AssistantTimeline()
        _ = t.reserve(count: 96_000, micHead: 0)
        t.reset()
        XCTAssertEqual(t.reserve(count: 100, micHead: 0), 0)
    }
}
