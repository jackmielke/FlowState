import XCTest
@testable import FlowStateCore

final class WakePhraseTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// The phrasing the recogniser actually produces, which a contains-check on the raw
    /// string would miss entirely.
    func testPunctuationAndCaseDoNotDefeatIt() {
        XCTAssertTrue(WakePhrase.heyFlow.matches("Hey, Flow."))
        XCTAssertTrue(WakePhrase.heyFlow.matches("HEY   FLOW"))
        XCTAssertTrue(WakePhrase.heyFlow.matches("okay so — hey, flow, are you there"))
    }

    func testMishearingsStillCount() {
        for heard in ["hey flo", "Hey Floe", "hey flow state"] {
            XCTAssertTrue(WakePhrase.heyFlow.matches(heard), "missed \(heard)")
        }
    }

    /// The word on its own is not the phrase — this is the whole reason for a two-word
    /// wake, and "flow" is a word this user says constantly.
    func testTheBareWordIsNotTheWakePhrase() {
        XCTAssertFalse(WakePhrase.heyFlow.matches("I was in flow all morning"))
        XCTAssertFalse(WakePhrase.heyFlow.matches("wispr flow is holding the microphone"))
        XCTAssertFalse(WakePhrase.heyFlow.matches("flow state"))
    }

    /// A live transcript is reported over and over as it is refined. One saying of the
    /// phrase, one wake.
    func testFiresOnceWhileTheTranscriptGrows() {
        var s = WakeListenerState()
        XCTAssertTrue(s.heard("hey flow", phrase: .heyFlow, now: at(0)))
        XCTAssertFalse(s.heard("hey flow are", phrase: .heyFlow, now: at(0.3)))
        XCTAssertFalse(s.heard("hey flow are you there", phrase: .heyFlow, now: at(0.9)))
    }

    /// The bug this tail rule exists for.
    ///
    /// A continuous recognition task reports one transcript that grows for up to a
    /// minute, so a phrase said once was still in that string forever — and the old
    /// "contains" check, plus a one-shot arm, meant the SECOND saying of it could never
    /// fire. Which is what "the wake word does not work" looked like from outside.
    func testSayingItAgainLaterFiresAgain() {
        var s = WakeListenerState()
        XCTAssertTrue(s.heard("hey flow", phrase: .heyFlow, now: at(0)))

        // …a minute of other conversation, all in the same transcript…
        let chatter = " so anyway I was thinking about the recording thing and whether it "
                    + "should follow me between screens which would be really impactful "
        XCTAssertFalse(s.heard("hey flow" + chatter, phrase: .heyFlow, now: at(20)))

        // …and then it is said again.
        XCTAssertTrue(s.heard("hey flow" + chatter + " hey flow", phrase: .heyFlow, now: at(30)))
    }

    /// And the phrase buried in the middle of a long transcript is history, not a wake.
    func testAnOldMatchStopsCounting() {
        var s = WakeListenerState()
        let old = "hey flow " + String(repeating: "and then we talked about it ", count: 6)
        _ = s.heard("hey flow", phrase: .heyFlow, now: at(0))
        XCTAssertFalse(s.heard(old, phrase: .heyFlow, now: at(30)))
    }

    func testRearmsOnTheNextUtterance() {
        var s = WakeListenerState()
        XCTAssertTrue(s.heard("hey flow", phrase: .heyFlow, now: at(0)))
        s.utteranceEnded()
        // Still inside the cooldown, so a repeat right away is refused.
        XCTAssertFalse(s.heard("hey flow", phrase: .heyFlow, now: at(1)))
        XCTAssertTrue(s.heard("hey flow", phrase: .heyFlow, now: at(10)))
    }

    func testArmedReportsWhetherItWouldFire() {
        var s = WakeListenerState()
        XCTAssertTrue(s.armed)
        _ = s.heard("hey flow", phrase: .heyFlow, now: at(0))
        XCTAssertFalse(s.armed)
        s.utteranceEnded()
        XCTAssertTrue(s.armed)
    }

    func testSilenceNeverWakesIt() {
        var s = WakeListenerState()
        XCTAssertFalse(s.heard("", phrase: .heyFlow, now: at(0)))
        XCTAssertFalse(s.heard("what were we saying", phrase: .heyFlow, now: at(1)))
    }
}

extension WakePhraseTests {

    /// The panic key's job: hanging up is not enough, because whatever caused the
    /// accidental wake is still going on and would trigger another one seconds later.
    func testSnoozeSuppressesTheWakePhrase() {
        var s = WakeListenerState()
        s.snooze(until: at(60))
        XCTAssertFalse(s.heard("hey flow", phrase: .heyFlow, now: at(1)))
        XCTAssertFalse(s.heard("hey flow", phrase: .heyFlow, now: at(59)))
    }

    func testItWakesAgainAfterTheSnooze() {
        var s = WakeListenerState()
        s.snooze(until: at(60))
        _ = s.heard("hey flow", phrase: .heyFlow, now: at(10))
        XCTAssertTrue(s.heard("hey flow", phrase: .heyFlow, now: at(61)))
    }

    /// A snooze that has been slept through is not a snooze, and must not keep it deaf.
    func testAnExpiredSnoozeIsIgnored() {
        var s = WakeListenerState()
        s.snooze(until: at(5))
        XCTAssertFalse(s.isSnoozed(at: at(6)))
    }
}
