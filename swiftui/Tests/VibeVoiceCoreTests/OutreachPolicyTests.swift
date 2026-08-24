import XCTest
@testable import VibeVoiceCore

final class OutreachPolicyTests: XCTestCase {

    private let policy = OutreachPolicy()
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func ctx(_ f: (inout OutreachContext) -> Void = { _ in }) -> OutreachContext {
        var c = OutreachContext(now: at(10))
        f(&c)
        return c
    }

    func testSpeaksWhenSomebodyIsThereAndFree() {
        XCTAssertEqual(policy.decide(ctx(), raisedAt: t0), .speak)
    }

    /// Mid-conversation there is nothing to interrupt, so it is said rather than
    /// announced — and none of the quiet rules should be able to suppress it.
    func testAlreadyTalkingMeansJustSayIt() {
        let c = ctx {
            $0.inSession = true
            $0.inMeeting = true
            $0.conferencingApp = true
            $0.withinHours = false
            $0.lastSpokeAt = self.at(9)
        }
        XCTAssertEqual(policy.decide(c, raisedAt: t0), .inline)
    }

    /// The expensive mistake: talking over somebody else's meeting.
    func testStaysQuietInAMeeting() {
        if case .hold = policy.decide(ctx { $0.inMeeting = true }, raisedAt: t0) {} else {
            XCTFail("spoke during a calendar event")
        }
        if case .hold = policy.decide(ctx { $0.conferencingApp = true }, raisedAt: t0) {} else {
            XCTFail("spoke with a conferencing app running")
        }
    }

    func testStaysQuietWhenNobodyIsThere() {
        if case .hold = policy.decide(ctx { $0.idleSeconds = 400 }, raisedAt: t0) {} else {
            XCTFail("spoke to an empty room")
        }
        if case .hold = policy.decide(ctx { $0.screenLocked = true }, raisedAt: t0) {} else {
            XCTFail("spoke to a locked screen")
        }
    }

    /// Away is reported as away even when a meeting is also in progress: it is the more
    /// certain of the two signals, and the truer thing to say afterwards.
    func testAwayIsPreferredOverGuessingAboutACall() {
        let c = ctx { $0.idleSeconds = 400; $0.conferencingApp = true }
        XCTAssertEqual(policy.decide(c, raisedAt: t0), .hold("you were away from your desk"))
    }

    func testDoesNotInterruptTwiceInARow() {
        let recent = ctx { $0.lastSpokeAt = self.at(9) }
        if case .hold = policy.decide(recent, raisedAt: t0) {} else { XCTFail("interrupted twice") }

        let longAgo = ctx { $0.lastSpokeAt = self.at(10 - 601) }
        XCTAssertEqual(policy.decide(longAgo, raisedAt: t0), .speak)
    }

    func testSnoozeAndHoursAreRespected() {
        if case .hold = policy.decide(ctx { $0.snoozedUntil = self.at(600) }, raisedAt: t0) {} else {
            XCTFail("spoke while snoozed")
        }
        // A snooze that has run out is not a snooze.
        XCTAssertEqual(policy.decide(ctx { $0.snoozedUntil = self.at(5) }, raisedAt: t0), .speak)
        if case .hold = policy.decide(ctx { $0.withinHours = false }, raisedAt: t0) {} else {
            XCTFail("spoke out of hours")
        }
    }

    /// Held news eventually stops being news. Announcing a two-hour-old result teaches
    /// the user that what it says is not current, which is worse than silence.
    func testStaleUpdatesAreDroppedNotHeld() {
        let c = OutreachContext(now: at(3 * 3_600))
        if case .drop = policy.decide(c, raisedAt: t0) {} else { XCTFail("announced old news") }
    }

    /// Staleness beats everything, including being mid-conversation.
    func testStalenessOutranksBeingInAConversation() {
        var c = OutreachContext(now: at(3 * 3_600))
        c.inSession = true
        if case .drop = policy.decide(c, raisedAt: t0) {} else { XCTFail("said stale news inline") }
    }

    /// Every hold carries something sayable, because an assistant that went quiet has to
    /// be able to explain why when it finally speaks.
    func testEveryHoldExplainsItself() {
        let holds = [
            ctx { $0.screenLocked = true },
            ctx { $0.idleSeconds = 400 },
            ctx { $0.inMeeting = true },
            ctx { $0.conferencingApp = true },
            ctx { $0.snoozedUntil = self.at(600) },
            ctx { $0.withinHours = false },
            ctx { $0.lastSpokeAt = self.at(9) },
        ]
        for c in holds {
            guard case .hold(let why) = policy.decide(c, raisedAt: t0) else {
                return XCTFail("expected a hold")
            }
            XCTAssertFalse(why.isEmpty)
            XCTAssertFalse(why.hasSuffix("."), "reasons are clauses, to be read into a sentence")
        }
    }
}
