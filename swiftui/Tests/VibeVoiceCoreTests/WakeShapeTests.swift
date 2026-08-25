import XCTest
@testable import VibeVoiceCore

/// The matcher against transcripts a recogniser actually produces, rather than
/// against the spelling somebody hoped for.
final class WakeShapeTests: XCTestCase {

    func testTheObviousOnes() {
        for said in ["Hey Flow", "hey flow", "Hey, Flow!", "hey flow are you there"] {
            XCTAssertTrue(WakePhrase.heyFlow.matches(said), "missed \(said)")
        }
    }

    /// The failure mode this replaced a variant list to fix: the recogniser hears
    /// something no list would contain. Vibey's heard "hey vibey" as "hey, if I
    /// be" — the shape survives where the spelling does not.
    func testManglingsStillCount() {
        // "hey pho" is deliberately NOT here: "pho" is a different word, not a
        // mangling of "flow", and a matcher loose enough to take it is loose
        // enough to wake on somebody ordering lunch.
        for said in ["hey flo", "hey floe", "hey flow w", "hay flow"] {
            XCTAssertTrue(WakePhrase.heyFlow.matches(said), "missed \(said)")
        }
    }

    /// Mentioning it is not addressing it. This is what the h-anchor buys, and
    /// without it "talking about flow" wakes the app mid-sentence.
    func testMentioningItDoesNotWakeIt() {
        for said in ["I was in flow all morning",
                     "wispr flow is holding the microphone",
                     "talking about flow state",
                     "the flow of the conversation"] {
            XCTAssertFalse(WakePhrase.heyFlow.matches(said), "false wake on \(said)")
        }
    }

    /// Real lines transcribed from the room while it was listening. None of these
    /// were addressed to it and none may wake it.
    func testOrdinarySpeechStaysWellUnder() {
        let overheard = [
            "which would be really impactful",
            "I think it used to be like, um,",
            "See what's happening, that was great.",
            "still definitely rougher at the engines.",
            "and everything makes sense from all.",
            "It's kind of surprising.",
        ]
        for line in overheard {
            let s = WakePhrase.heyFlow.score(line)
            XCTAssertLessThan(s, WakePhrase.threshold, "\(line) scored \(s)")
        }
    }

    func testSilenceScoresNothing() {
        XCTAssertEqual(WakePhrase.heyFlow.score(""), 0)
        XCTAssertEqual(WakePhrase.heyFlow.score("   "), 0)
    }
}
