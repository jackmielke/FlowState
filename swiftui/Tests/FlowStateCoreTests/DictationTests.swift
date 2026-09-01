import XCTest
@testable import FlowStateCore

/// Dictation's state machine and its text cleanup.
///
/// Two classes of bug live here and both are invisible in a demo. The first is the double
/// press: hold the hotkey, release, then press again before the first utterance has come
/// back, and two half-sentences interleave at the cursor. The second is over-eager
/// punctuation replacement — "the period of time" becoming "the . of time" is the kind of
/// thing you only notice after you have sent the message.
final class DictationTests: XCTestCase {

    // MARK: - Session

    func test_happyPathRunsIdleToIdle() {
        var s = Dictation.Session()
        XCTAssertEqual(s.phase, .idle)
        XCTAssertTrue(s.beginListening())
        XCTAssertEqual(s.phase, .listening)
        XCTAssertTrue(s.finishListening())
        XCTAssertEqual(s.phase, .transcribing)
        XCTAssertTrue(s.transcribed("hello there"))
        XCTAssertEqual(s.phase, .inserting)
        s.finished()
        XCTAssertEqual(s.phase, .idle)
    }

    /// The double press. A second start must be refused, not queued and not allowed to
    /// clobber the utterance already in flight.
    func test_secondPressWhileTranscribingIsRefused() {
        var s = Dictation.Session()
        s.beginListening()
        s.finishListening()
        XCTAssertEqual(s.phase, .transcribing)

        XCTAssertFalse(s.beginListening())
        XCTAssertEqual(s.phase, .transcribing, "the in-flight utterance must survive")
        XCTAssertNotNil(s.lastRefusal, "the UI has to be able to say why nothing happened")
    }

    /// A key press with no speech is the most common non-happy path — it must not try to
    /// insert an empty string into the frontmost app.
    func test_emptyTranscriptReturnsToIdleWithoutInserting() {
        var s = Dictation.Session()
        s.beginListening()
        s.finishListening()
        XCTAssertTrue(s.transcribed("   \n  "))
        XCTAssertEqual(s.phase, .idle)
    }

    func test_outOfOrderEventsAreRefusedRatherThanTrapping() {
        var s = Dictation.Session()
        XCTAssertFalse(s.finishListening())
        XCTAssertFalse(s.transcribed("stray"))
        XCTAssertEqual(s.phase, .idle)
    }

    func test_cancelAlwaysReachesIdle() {
        for setup in [0, 1, 2] {
            var s = Dictation.Session()
            if setup >= 1 { s.beginListening() }
            if setup >= 2 { s.finishListening() }
            s.cancel()
            XCTAssertEqual(s.phase, .idle)
            XCTAssertNil(s.lastRefusal)
        }
    }

    // MARK: - tidy

    func test_spokenPunctuationBecomesPunctuation() {
        XCTAssertEqual(Dictation.tidy("hello there comma how are you question mark"),
                       "Hello there, how are you?")
    }

    func test_newLineAndNewParagraph() {
        XCTAssertEqual(Dictation.tidy("first line new line second line"),
                       "First line\nSecond line")
        XCTAssertEqual(Dictation.tidy("one new paragraph two"),
                       "One\n\nTwo")
    }

    /// The false positive that matters. An article before the word means it is being used
    /// as a noun, not as a command.
    func test_articleLedPunctuationWordsAreLeftAlone() {
        XCTAssertEqual(Dictation.tidy("over the period of a year"),
                       "Over the period of a year")
        XCTAssertEqual(Dictation.tidy("a comma is punctuation"),
                       "A comma is punctuation")
    }

    /// Substring matches must not fire: "periodic" is not "period".
    func test_punctuationWordsMustBeWholeWords() {
        XCTAssertEqual(Dictation.tidy("periodic checks"), "Periodic checks")
        XCTAssertEqual(Dictation.tidy("commander"), "Commander")
    }

    func test_leadingFillerIsDroppedButInternalFillerIsKept() {
        XCTAssertEqual(Dictation.tidy("um so I was thinking"), "So I was thinking")
        XCTAssertEqual(Dictation.tidy("he said um and then left"),
                       "He said um and then left",
                       "editing the middle of a sentence makes the output need proofreading")
    }

    func test_sentencesAreCapitalizedAfterTerminators() {
        XCTAssertEqual(Dictation.tidy("one period two period"), "One. Two.")
    }

    func test_emptyAndWhitespaceInputAreSafe() {
        XCTAssertEqual(Dictation.tidy(""), "")
        XCTAssertEqual(Dictation.tidy("   \n "), "")
    }

    func test_longestPhraseWinsOverItsPrefix() {
        XCTAssertEqual(Dictation.tidy("done exclamation point"), "Done!")
    }
}
