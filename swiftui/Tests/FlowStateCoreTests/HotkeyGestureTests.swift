import XCTest
@testable import FlowStateCore

/// Telling a hold from a tap on one key.
///
/// The bug this file exists to prevent: acting on key-down. It looks correct in a demo
/// because a single hold works, and it is wrong for every tap — the mic would open on the
/// way to a toggle the user only meant to fire once released. Every test below is a shape
/// that a key-down-triggered implementation gets wrong.
final class HotkeyGestureTests: XCTestCase {

    private func recognizer() -> HotkeyGesture.Recognizer {
        HotkeyGesture.Recognizer(holdThreshold: 0.25)
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
        // A release before the threshold is a tap, not a hold — it toggles immediately
        // rather than beginning dictation.
        XCTAssertEqual(r.keyUp(at: 0.1), .startVoiceMode)
        XCTAssertFalse(r.isDictating)
        XCTAssertNil(r.tick(at: 0.5), "nothing left pending once the tap has resolved")
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

    // MARK: - Tap toggles

    func test_tapNeverBeginsDictation() {
        var r = recognizer()
        XCTAssertNil(r.keyDown(at: 0))
        XCTAssertEqual(r.keyUp(at: 0.08), .startVoiceMode)
        XCTAssertFalse(r.isDictating, "the mic must never have opened")
    }

    /// A second tap right after the first is just another toggle — off again — not a
    /// distinct "double press" gesture.
    func test_secondQuickTapTogglesBackOff() {
        var r = recognizer()
        r.isVoiceModeActive = false
        r.keyDown(at: 0)
        XCTAssertEqual(r.keyUp(at: 0.08), .startVoiceMode)
        r.isVoiceModeActive = true
        r.keyDown(at: 0.20)
        XCTAssertEqual(r.keyUp(at: 0.28), .stopVoiceMode)
    }

    /// Hold, release, then press again quickly is two intentions, not one gesture — the
    /// user dictated and then wants to toggle voice mode.
    func test_holdFollowedByQuickTapIsASeparatePress() {
        var r = recognizer()
        r.keyDown(at: 0)
        XCTAssertEqual(r.tick(at: 0.25), .beginDictation)
        XCTAssertEqual(r.keyUp(at: 1.0), .endDictation)
        XCTAssertNil(r.keyDown(at: 1.05), "must begin a fresh press")
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

    // MARK: - Toggling a running session

    /// Jack's rule: one press toggles. While a session is running the tap must act on
    /// key-up with no delay — a hang-up key with any lag feels broken.
    func test_singleTapWhileVoiceModeRunningStopsItImmediately() {
        var r = recognizer()
        r.isVoiceModeActive = true
        r.keyDown(at: 0)
        XCTAssertEqual(r.keyUp(at: 0.08), .stopVoiceMode)
        XCTAssertNil(r.nextDeadline, "no timer should be left armed")
    }

    /// The mirror image: the same tap with nothing running starts it, just as promptly.
    func test_singleTapWhileIdleStartsItImmediately() {
        var r = recognizer()
        r.isVoiceModeActive = false
        r.keyDown(at: 0)
        XCTAssertEqual(r.keyUp(at: 0.08), .startVoiceMode)
        XCTAssertNil(r.nextDeadline, "no timer should be left armed")
    }

    /// Holding still dictates even mid-session — only the tap path changes behaviour.
    func test_holdStillDictatesWhileVoiceModeRunning() {
        var r = recognizer()
        r.isVoiceModeActive = true
        r.keyDown(at: 0)
        XCTAssertEqual(r.tick(at: 0.25), .beginDictation)
        XCTAssertEqual(r.keyUp(at: 1.0), .endDictation)
    }

    /// A key-up with no matching key-down happens when the hotkey is rebound mid-press.
    func test_strayKeyUpIsIgnored() {
        var r = recognizer()
        XCTAssertNil(r.keyUp(at: 1.0))
        XCTAssertFalse(r.isDictating)
    }
}
