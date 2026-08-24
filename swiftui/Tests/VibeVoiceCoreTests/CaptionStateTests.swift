import XCTest
@testable import VibeVoiceCore

final class CaptionStateTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testNothingIsShownBeforeAnythingIsSaid() {
        XCTAssertFalse(CaptionState().visible(at: t0))
    }

    /// The important one: a long answer must not vanish while it is still being spoken.
    func testAnUnfinishedLineNeverTimesOut() {
        var c = CaptionState()
        c.say(.assistant, "Let me think about that", at: t0)
        XCTAssertTrue(c.visible(at: at(60)))
        XCTAssertTrue(c.visible(at: at(600)))
    }

    func testAFinishedLineLingersThenGoes() {
        var c = CaptionState()
        c.say(.assistant, "Done.", at: t0, done: true)
        XCTAssertTrue(c.visible(at: at(3.9)))
        XCTAssertFalse(c.visible(at: at(4.1)))
    }

    /// Every delta restarts the clock, so a streaming reply stays up throughout.
    func testStreamingKeepsItAlive() {
        var c = CaptionState()
        c.say(.assistant, "One", at: t0, done: true)
        c.say(.assistant, "One two", at: at(3), done: true)
        XCTAssertTrue(c.visible(at: at(6.5)), "the second delta should have restarted the clock")
        XCTAssertFalse(c.visible(at: at(7.1)))
    }

    /// A caption is read as it is spoken, so the useful end is the newest words.
    func testKeepsTheEndNotTheBeginning() {
        var c = CaptionState()
        let long = (1...60).map { "word\($0)" }.joined(separator: " ")
        c.say(.assistant, long, at: t0)
        let shown = c.line?.text ?? ""
        XCTAssertTrue(shown.hasPrefix("…"))
        XCTAssertTrue(shown.hasSuffix("word60"), shown)
        XCTAssertLessThanOrEqual(shown.count, 181)
    }

    /// Cut mid-word it reads as a bug rather than an excerpt.
    func testTruncationLandsOnAWordBoundary() {
        let s = CaptionState.tail("alpha bravo charlie delta echo foxtrot", limit: 20)
        XCTAssertTrue(s.hasPrefix("…"))
        XCTAssertFalse(s.dropFirst().hasPrefix(" "))
        XCTAssertTrue("alpha bravo charlie delta echo foxtrot".hasSuffix(String(s.dropFirst())), s)
    }

    func testShortTextIsLeftAlone() {
        XCTAssertEqual(CaptionState.tail("hello there", limit: 180), "hello there")
    }

    func testBlankUpdatesAreIgnored() {
        var c = CaptionState()
        c.say(.assistant, "   ", at: t0)
        XCTAssertNil(c.line)
    }

    func testClearHidesItAtOnce() {
        var c = CaptionState()
        c.say(.user, "what's the weather", at: t0)
        c.clear()
        XCTAssertFalse(c.visible(at: t0))
    }

    func testTheSpeakerIsCarried() {
        var c = CaptionState()
        c.say(.user, "hello", at: t0)
        XCTAssertEqual(c.line?.speaker, .user)
        c.say(.assistant, "hi", at: t0)
        XCTAssertEqual(c.line?.speaker, .assistant)
    }
}

extension CaptionStateTests {

    /// Hovering is only offered when something is actually hidden, so the panel knows
    /// whether to take the mouse at all.
    func testTruncationIsReported() {
        var c = CaptionState()
        c.say(.assistant, "short", at: t0)
        XCTAssertFalse(c.wasTruncated)

        c.say(.assistant, String(repeating: "word ", count: 80), at: t0)
        XCTAssertTrue(c.wasTruncated)
    }

    /// And the whole thing is kept, so there is something to reveal.
    func testTheFullTextSurvivesTruncation() {
        var c = CaptionState()
        let long = (1...60).map { "word\($0)" }.joined(separator: " ")
        c.say(.assistant, long, at: t0)
        XCTAssertEqual(c.line?.full, long)
        XCTAssertNotEqual(c.line?.text, long)
    }

    func testTruncationResetsWithTheLine() {
        var c = CaptionState()
        c.say(.assistant, String(repeating: "word ", count: 80), at: t0)
        c.clear()
        XCTAssertFalse(c.wasTruncated)
    }
}
