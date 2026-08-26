import XCTest
@testable import VibeVoiceCore

/// Telling a hold from a double press on one key.
///
/// The bug this file exists to prevent: acting on key-down. It looks correct in a demo
/// because a single hold works, and it is wrong for every double press — the first press
/// opens the mic, the second toggles voice mode, and the user is left dictating into a
/// conversation they did not mean to start. Every test below is a shape that a
/// key-down-triggered implementation gets wrong.
final class HotkeyGestureTests: XCTestCase {

    private func recognizer() -> HotkeyGesture.Recognizer {
        HotkeyGesture.Recognizer(holdThreshold: 0.25, doubleTapWindow: 0.35)
    }

    // MARK: - Hold

    func test_holdingPastThresholdBeginsDictation() {
        var r = recognizer()
        XCTAssertNil(r.keyDown(at: 0), "key-down alone must not commit to anything")
        XCTAssertEqual(r.tick(at: 0.25), .beginDictation)
        XCTAssertTrue(r.isDictating)
        XCTAssertEqual(r.keyUp(at: 2.0), .endDictation)
        XCTAssertFalse(r.isDictating)
    }

    func test_releasingBeforeThresholdIsNotAHold() {
        var r = recognizer()
        r.keyDown(at: 0)
        XCTAssertNil(r.keyUp(at: 0.1))
        XCTAssertFalse(r.isDictating)
        // And the lone tap expires into nothing rather than firing late.
        XCTAssertNil(r.tick(at: 0.5))
    }

    /// Key repeat fires many downs while held. Restarting the clock on each one would mean
    /// a long hold never crosses the threshold.
    func test_keyRepeatDoesNotRestartTheHoldClock() {
        var r = recognizer()
        r.keyDown(at: 0)
        XCTAssertNil(r.keyDown(at: 0.05))
        XCTAssertNil(r.keyDown(at: 0.10))
        XCTAssertEqual(r.tick(at: 0.25), .beginDictation)
    }

    // MARK: - Double press

    func test_twoQuickTapsToggleVoiceMode() {
        var r = recognizer()
        r.keyDown(at: 0)
        XCTAssertNil(r.keyUp(at: 0.08), "first tap must stay pending")
        XCTAssertEqual(r.keyDown(at: 0.20), .toggleVoiceMode)
    }

    /// The whole point of rule 1: the first press of a double press must not have started
    /// dictation on its way through.
    func test_doublePressNeverBeginsDictation() {
        var r = recognizer()
        XCTAssertNil(r.keyDown(at: 0))
        XCTAssertNil(r.keyUp(at: 0.08))
        XCTAssertEqual(r.keyDown(at: 0.20), .toggleVoiceMode)
        XCTAssertFalse(r.isDictating, "the mic must never have opened")
    }

    func test_secondTapArrivingTooLateStartsOver() {
        var r = recognizer()
        r.keyDown(at: 0)
        r.keyUp(at: 0.08)
        XCTAssertNil(r.tick(at: 0.43), "window expired, lone tap discarded")
        XCTAssertNil(r.keyDown(at: 0.50), "this is a new first press, not a double")
    }

    /// Rule 2. Hold, release, then press again quickly is two intentions, not a double
    /// press — the user dictated and then wanted voice mode.
    func test_holdFollowedByQuickPressIsNotADoublePress() {
        var r = recognizer()
        r.keyDown(at: 0)
        XCTAssertEqual(r.tick(at: 0.25), .beginDictation)
        XCTAssertEqual(r.keyUp(at: 1.0), .endDictation)
        XCTAssertNil(r.keyDown(at: 1.05), "must begin a fresh press, not toggle voice mode")
        XCTAssertEqual(r.tick(at: 1.30), .beginDictation, "and it can become another hold")
    }

    // MARK: - Deadlines

    /// The driver schedules one timer from this rather than polling; a nil when something
    /// is pending means the gesture silently never fires.
    func test_deadlineIsAdvertisedWhileSomethingIsPending() throws {
        var r = recognizer()
        XCTAssertNil(r.nextDeadline, "idle needs no timer")

        r.keyDown(at: 10)
        XCTAssertEqual(try XCTUnwrap(r.nextDeadline), 10.25, accuracy: 0.0001, "hold threshold")

        _ = r.tick(at: 10.25)
        XCTAssertNil(r.nextDeadline, "holding waits on key-up, not a clock")

        _ = r.keyUp(at: 11)
        XCTAssertNil(r.nextDeadline, "back to idle")
    }

    func test_deadlineAfterATapIsTheDoubleTapWindow() throws {
        var r = recognizer()
        r.keyDown(at: 5)
        r.keyUp(at: 5.1)
        // accuracy rather than equality: 5.1 + 0.35 is 5.449999999999999 in binary
        // floating point, and a deadline is a moment to schedule a timer for, not a value
        // anyone compares exactly.
        XCTAssertEqual(try XCTUnwrap(r.nextDeadline), 5.45, accuracy: 0.0001)
    }

    // MARK: - Reset

    func test_resetWhileHoldingReportsCancellation() {
        var r = recognizer()
        r.keyDown(at: 0)
        _ = r.tick(at: 0.25)
        XCTAssertEqual(r.reset(), .cancelDictation, "the open mic has to be torn down")
        XCTAssertFalse(r.isDictating)
    }

    func test_resetWhenIdleIsSilent() {
        var r = recognizer()
        XCTAssertNil(r.reset())
    }

    /// A key-up with no matching key-down happens when the hotkey is rebound mid-press.
    func test_strayKeyUpIsIgnored() {
        var r = recognizer()
        XCTAssertNil(r.keyUp(at: 1.0))
        XCTAssertFalse(r.isDictating)
    }
}
