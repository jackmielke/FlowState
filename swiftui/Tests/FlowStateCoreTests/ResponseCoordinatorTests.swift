import XCTest
@testable import FlowStateCore

/// Records everything the coordinator does, including the phase it was in at the moment
/// it put something on the wire — that pairing is the invariant the whole type exists to
/// hold up, so it is worth asserting directly.
private final class Recorder {
    var sent: [(out: ResponseCoordinator.Outbound, phase: ResponseCoordinator.Phase)] = []
    var events: [ResponseCoordinator.Event] = []
    var changes = 0

    var creates: Int { sent.filter { $0.out == .create }.count }
    var cancels: Int { sent.filter { $0.out == .cancel }.count }
    var kinds: [ResponseCoordinator.Event.Kind] { events.map(\.kind) }

    func detail(_ kind: ResponseCoordinator.Event.Kind) -> String? {
        events.last(where: { $0.kind == kind })?.detail
    }
}

private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ s: TimeInterval) { now += s }
}

/// Every test drives the clock by hand — nothing here sleeps, so the watchdog paths are
/// as deterministic as the happy ones.
@MainActor
final class ResponseCoordinatorTests: XCTestCase {

    private let dup = "Conversation already has an active response in progress"

    private func makeSUT(
        _ timeouts: ResponseCoordinator.Timeouts = ResponseCoordinator.Timeouts()
    ) -> (ResponseCoordinator, Recorder, TestClock) {
        let clock = TestClock()
        let rec = Recorder()
        let sut = ResponseCoordinator(timeouts: timeouts, now: { clock.now })
        sut.send = { [unowned sut] out in rec.sent.append((out: out, phase: sut.phase)) }
        sut.log = { rec.events.append($0) }
        sut.onChange = { rec.changes += 1 }
        return (sut, rec, clock)
    }

    // MARK: - The bug: two creates on the wire

    func test_firstRequestSendsExactlyOneCreate() {
        let (sut, rec, _) = makeSUT()

        sut.request(reason: "screenshot")

        XCTAssertEqual(rec.creates, 1)
        XCTAssertEqual(sut.phase, .requested)
        XCTAssertFalse(sut.hasQueuedRequest)
    }

    /// The regression this whole change is about. The old code only flipped its flag on
    /// `response.created`, so a second request arriving in the round trip before that
    /// event looked legal and put a second `response.create` on the wire — which the API
    /// answers with "Conversation already has an active response in progress".
    func test_requestBeforeServerConfirmsDoesNotSendASecondCreate() {
        let (sut, rec, _) = makeSUT()

        sut.request(reason: "tool-output")
        sut.request(reason: "screenshot")        // same round trip, no response.created yet

        XCTAssertEqual(rec.creates, 1, "a second create in the confirm window is the bug")
        XCTAssertEqual(sut.phase, .requested)
        XCTAssertEqual(sut.queuedCount, 1)

        sut.responseCreated(id: "resp_1")
        sut.request(reason: "claude-code-finished")
        XCTAssertEqual(rec.creates, 1)
        XCTAssertEqual(sut.queuedCount, 2)

        sut.responseFinished()
        XCTAssertEqual(rec.creates, 2, "deferred work goes out once the response is done")
        XCTAssertEqual(sut.queuedCount, 0)
    }

    /// Server VAD creates responses on its own (`turn_detection.create_response: true`),
    /// so the app can be busy without ever having asked for anything.
    func test_requestDuringAServerStartedResponseIsDeferredNotDropped() {
        let (sut, rec, _) = makeSUT()

        sut.responseCreated(id: "resp_vad")      // nobody asked; the user just spoke
        XCTAssertEqual(sut.phase, .active)

        sut.request(reason: "screenshot")
        XCTAssertEqual(rec.creates, 0)
        XCTAssertTrue(sut.hasQueuedRequest)

        sut.responseFinished()
        XCTAssertEqual(rec.creates, 1)
        XCTAssertEqual(rec.sent.last?.phase, .requested)
    }

    func test_manyDeferredRequestsCoalesceIntoASingleCreate() {
        let (sut, rec, _) = makeSUT()

        sut.responseCreated(id: "resp_1")
        sut.request(reason: "screenshot")
        sut.request(reason: "tool-output")
        sut.request(reason: "claude-code-finished")
        XCTAssertEqual(sut.queuedCount, 3)

        sut.responseFinished()

        XCTAssertEqual(rec.creates, 1, "three deferred asks are one turn, not three")
        XCTAssertEqual(rec.detail(.sent), "screenshot + tool-output + claude-code-finished")
    }

    /// A response that fails or is cancelled still ends. Treating only "completed" as the
    /// release point is how an app goes permanently mute.
    func test_lockIsReleasedWhateverTheResponseStatus() {
        // Nothing queued: finishing must return the coordinator to idle, so the next
        // ask is sent immediately rather than waiting behind a lock nobody holds.
        for status in ["completed", "cancelled", "failed", "incomplete"] {
            let (sut, rec, _) = makeSUT()
            sut.responseCreated(id: "resp_1")

            sut.responseFinished(status: status)

            XCTAssertEqual(sut.phase, .idle, "status=\(status)")
            XCTAssertEqual(rec.creates, 0, "nothing was queued, status=\(status)")
        }

        // Something queued: finishing must flush it. The phase is then `.requested`,
        // not `.idle` — the lock was released and immediately retaken by the deferred
        // turn, which is the whole point of deferring rather than dropping.
        for status in ["completed", "cancelled", "failed", "incomplete"] {
            let (sut, rec, _) = makeSUT()
            sut.responseCreated(id: "resp_1")
            sut.request(reason: "screenshot")

            sut.responseFinished(status: status)

            XCTAssertEqual(sut.phase, .requested, "status=\(status)")
            XCTAssertEqual(rec.creates, 1, "deferred turn was sent, status=\(status)")
        }
    }

    /// The invariant, stated directly: a create only ever leaves while the coordinator is
    /// taking the lock, and a cancel only while it is releasing one.
    func test_neverSendsWhileBusy() {
        let (sut, rec, clock) = makeSUT()

        sut.request(reason: "a")
        sut.request(reason: "b")
        sut.responseCreated(id: "resp_1")
        sut.request(reason: "c")
        sut.userSpeechStarted()
        sut.request(reason: "d")
        sut.userSpeechStopped()
        sut.responseFinished()
        clock.advance(5)
        sut.tick()
        sut.responseCreated(id: "resp_2")
        sut.cancel(reason: "user pressed Stop")
        sut.responseFinished(status: "cancelled")

        for (out, phase) in rec.sent {
            switch out {
            case .create: XCTAssertEqual(phase, .requested)
            case .cancel: XCTAssertEqual(phase, .cancelling)
            }
        }
        XCTAssertEqual(rec.creates, 2)
        XCTAssertEqual(rec.cancels, 1)
    }

    // MARK: - Error recovery

    func test_duplicateCreateErrorIsRepairedAndTheRequestIsRequeued() {
        let (sut, rec, _) = makeSUT()

        sut.request(reason: "screenshot")
        let handled = sut.apiError(dup)

        XCTAssertTrue(handled, "the user must not be shown an error the app can fix")
        XCTAssertEqual(sut.phase, .active, "the server says a response is running — believe it")
        XCTAssertEqual(sut.queuedCount, 1, "the screenshot still deserves an answer")
        XCTAssertEqual(rec.creates, 1, "no blind immediate retry")

        sut.responseFinished()
        XCTAssertEqual(rec.creates, 2)
        XCTAssertEqual(rec.detail(.sent), "screenshot")
    }

    func test_duplicateCreateErrorTakesTheLockEvenIfWeThoughtWeWereIdle() {
        let (sut, _, _) = makeSUT()

        XCTAssertTrue(sut.apiError(dup))

        XCTAssertEqual(sut.phase, .active)
    }

    func test_cancellationFailedErrorReturnsToIdle() {
        let (sut, rec, _) = makeSUT()

        sut.request(reason: "screenshot")
        sut.cancel(reason: "user pressed Stop")
        XCTAssertEqual(sut.phase, .cancelling)

        let handled = sut.apiError("Cancellation failed: no active response found")

        XCTAssertTrue(handled)
        XCTAssertEqual(sut.phase, .idle)
        XCTAssertEqual(rec.creates, 1)
    }

    /// An unrelated error must not free the lock — a response is still streaming, and
    /// "recovering" from someone else's problem would put a second create on the wire.
    func test_unrelatedErrorIsSurfacedAndLeavesThePhaseAlone() {
        let (sut, rec, _) = makeSUT()

        sut.request(reason: "screenshot")
        sut.responseCreated(id: "resp_1")

        let handled = sut.apiError("Invalid value: 'item_9'. Item does not exist.")

        XCTAssertFalse(handled, "the banner is right for errors the app cannot fix")
        XCTAssertEqual(sut.phase, .active)
        XCTAssertEqual(rec.creates, 1)
    }

    // MARK: - Cancel and reset

    func test_cancelStopsTheResponseAndAbandonsQueuedWork() {
        let (sut, rec, _) = makeSUT()

        sut.responseCreated(id: "resp_1")
        sut.request(reason: "screenshot")
        sut.cancel(reason: "user pressed Stop")

        XCTAssertEqual(rec.cancels, 1)
        XCTAssertEqual(sut.phase, .cancelling)
        XCTAssertFalse(sut.hasQueuedRequest, "Stop means silence, not silence-then-talking")
        XCTAssertTrue(rec.kinds.contains(.cancelRequested))
        XCTAssertTrue(rec.kinds.contains(.dropped))

        sut.responseFinished(status: "cancelled")
        XCTAssertEqual(sut.phase, .idle)
        XCTAssertEqual(rec.creates, 0)
    }

    /// The escape hatch: a cancel the server never acknowledges must not trap the UI in
    /// "stopping…" forever.
    func test_cancellingTwiceForcesIdle() {
        let (sut, rec, _) = makeSUT()

        sut.responseCreated(id: "resp_1")
        sut.cancel(reason: "user pressed Stop")
        sut.cancel(reason: "user pressed Stop again")

        XCTAssertEqual(sut.phase, .idle)
        XCTAssertEqual(rec.cancels, 1, "the second press is local, not another message")
    }

    func test_cancelWithNothingRunningIsANoOp() {
        let (sut, rec, _) = makeSUT()

        sut.cancel(reason: "user pressed Stop")

        XCTAssertEqual(sut.phase, .idle)
        XCTAssertTrue(rec.sent.isEmpty)
        XCTAssertTrue(rec.kinds.contains(.ignored))
    }

    /// A queued create left over from a dead socket firing into the NEXT session is
    /// exactly how a fresh conversation greets you with someone else's answer.
    func test_resetClearsEverythingAndSendsNothing() {
        let (sut, rec, clock) = makeSUT()

        sut.responseCreated(id: "resp_1")
        sut.request(reason: "screenshot")
        sut.reset(reason: "disconnect")

        XCTAssertEqual(sut.phase, .idle)
        XCTAssertFalse(sut.hasQueuedRequest)
        XCTAssertTrue(rec.sent.isEmpty)

        clock.advance(600)
        sut.tick()
        XCTAssertTrue(rec.sent.isEmpty, "nothing may be sent on a socket that is gone")
    }

    // MARK: - Watchdog

    func test_aCreateTheServerNeverConfirmsIsRetriedNotLeftHanging() {
        let (sut, rec, clock) = makeSUT()

        sut.request(reason: "screenshot")
        XCTAssertEqual(sut.phase, .requested)

        clock.advance(11)                       // confirm timeout is 10s
        sut.tick()

        XCTAssertTrue(rec.kinds.contains(.timedOut))
        XCTAssertEqual(rec.creates, 2, "the turn the user asked for is retried, not lost")
        XCTAssertEqual(sut.phase, .requested)
    }

    func test_aResponseThatNeverFinishesIsCancelledThenForcedIdle() {
        let (sut, rec, clock) = makeSUT()

        sut.request(reason: "screenshot")
        sut.responseCreated(id: "resp_1")

        clock.advance(181)                      // response timeout is 180s
        sut.tick()
        XCTAssertEqual(sut.phase, .cancelling)
        XCTAssertEqual(rec.cancels, 1)

        clock.advance(6)                        // cancel timeout is 5s
        sut.tick()
        XCTAssertEqual(sut.phase, .idle, "a wedged session must always come back on its own")
    }

    func test_theWatchdogIsQuietWhileThingsAreNormal() {
        let (sut, rec, clock) = makeSUT()

        sut.request(reason: "screenshot")
        sut.responseCreated(id: "resp_1")
        for _ in 0..<30 { clock.advance(1); sut.tick() }

        XCTAssertEqual(sut.phase, .active)
        XCTAssertFalse(rec.kinds.contains(.timedOut))
        XCTAssertEqual(rec.creates, 1)
    }

    func test_retriesAreAbandonedAfterTheStrikeLimit() {
        let (sut, rec, clock) = makeSUT()

        sut.request(reason: "screenshot")
        for _ in 0..<4 {                        // four confirm timeouts in a row
            clock.advance(11)
            sut.tick()
        }

        XCTAssertEqual(rec.creates, sut.maxStrikes, "retrying forever is not recovery")
        XCTAssertFalse(sut.hasQueuedRequest)
        XCTAssertEqual(sut.phase, .idle)
        XCTAssertTrue(rec.kinds.contains(.dropped))
    }

    // MARK: - Turn-taking with server VAD

    /// Server VAD opens a turn of its own the moment the user stops talking. Firing a
    /// queued create into that window is a guaranteed collision, so it waits.
    func test_aQueuedRequestWaitsWhileTheUserIsSpeaking() {
        let (sut, rec, clock) = makeSUT()

        sut.userSpeechStarted()
        sut.request(reason: "claude-code-finished")
        XCTAssertEqual(rec.creates, 0)
        XCTAssertEqual(rec.detail(.queued), "claude-code-finished — user is speaking")

        sut.userSpeechStopped()
        XCTAssertTrue(rec.kinds.contains(.held), "the grace window is logged, not silent")
        sut.tick()
        XCTAssertEqual(rec.creates, 0, "still inside the grace window")

        clock.advance(2)                        // grace is 1.5s
        sut.tick()
        XCTAssertEqual(rec.creates, 1)
    }

    /// `speech_started` with no `speech_stopped` behind it must not hold the queue shut
    /// forever — that is silence with no way out.
    func test_aLostSpeechStoppedEventualyReleasesTheHold() {
        let (sut, rec, clock) = makeSUT()

        sut.userSpeechStarted()
        sut.request(reason: "claude-code-finished")
        clock.advance(60)
        sut.tick()
        XCTAssertEqual(rec.creates, 0, "a long monologue is still a legitimate hold")

        clock.advance(200)                      // past the 180s ceiling
        sut.tick()

        XCTAssertEqual(rec.creates, 1)
        XCTAssertFalse(sut.userSpeaking)
        XCTAssertTrue(rec.kinds.contains(.timedOut))
    }

    func test_theServersOwnTurnWinsTheRaceAndOursFollowsIt() {
        let (sut, rec, clock) = makeSUT()

        sut.userSpeechStarted()
        sut.request(reason: "claude-code-finished")
        sut.userSpeechStopped()

        sut.responseCreated(id: "resp_vad")     // the server got there first
        clock.advance(5)
        sut.tick()
        XCTAssertEqual(rec.creates, 0, "never on top of the server's own turn")

        sut.responseFinished()
        XCTAssertEqual(rec.creates, 1)
    }

    // MARK: - Logging

    func test_everyLifecycleStepIsLogged() {
        let (sut, rec, clock) = makeSUT()

        sut.request(reason: "screenshot")                       // sent
        sut.request(reason: "tool-output")                      // queued
        sut.responseCreated(id: "resp_1")                       // started
        sut.responseFinished()                                  // finished
        sut.responseCreated(id: "resp_2")
        sut.cancel(reason: "user pressed Stop")                 // cancelRequested
        sut.responseFinished(status: "cancelled")
        _ = sut.apiError(dup)                                   // recovered
        clock.advance(400)
        sut.tick()                                              // timedOut
        sut.reset(reason: "disconnect")                         // reset

        for kind in [ResponseCoordinator.Event.Kind.sent, .queued, .started, .finished,
                     .cancelRequested, .recovered, .timedOut, .reset] {
            XCTAssertTrue(rec.kinds.contains(kind), "missing log for \(kind.rawValue)")
        }
        XCTAssertTrue(rec.events.allSatisfy { !$0.line.isEmpty })
    }

    func test_theUIIsToldWhenAnythingChanges() {
        let (sut, rec, _) = makeSUT()

        sut.request(reason: "screenshot")
        let afterRequest = rec.changes
        sut.responseCreated(id: "resp_1")
        sut.responseFinished()

        XCTAssertGreaterThan(afterRequest, 0)
        XCTAssertGreaterThan(rec.changes, afterRequest)
    }

    /// A quiet tick must not repaint the UI 60 times a minute for nothing.
    func test_anIdleTickChangesNothing() {
        let (sut, rec, clock) = makeSUT()

        sut.request(reason: "screenshot")
        sut.responseCreated(id: "resp_1")
        let before = rec.changes
        clock.advance(1)
        sut.tick()

        XCTAssertEqual(rec.changes, before)
    }
}
