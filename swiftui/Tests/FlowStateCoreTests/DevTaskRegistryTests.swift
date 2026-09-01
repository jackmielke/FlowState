import XCTest
@testable import FlowStateCore

final class DevTaskRegistryTests: XCTestCase {

    func test_severalTasksRunAtOnceAcrossDifferentRepos() {
        let r = DevTaskRegistry(maxConcurrent: 3)
        r.start(label: "orb", repo: "~/dev/vibe-voice")
        r.start(label: "radish", repo: "~/dev/ravishing-radish")
        r.start(label: "site", repo: "~/dev/jack-mielke")
        XCTAssertEqual(r.running.count, 3)
    }

    /// The rule this whole type exists for. Two Claude Code runs in one checkout break
    /// each other — observed as "input file was modified during the build" when one
    /// wrote while the other compiled.
    func test_secondTaskInTheSameRepoIsRefused() {
        let r = DevTaskRegistry(maxConcurrent: 3)
        let first = r.start(label: "orb", repo: "~/dev/vibe-voice")

        XCTAssertEqual(r.rejectionFor(repo: "~/dev/vibe-voice"),
                       .repoBusy(taskID: first.id, repo: "~/dev/vibe-voice"))
        XCTAssertFalse(r.canStart(repo: "~/dev/vibe-voice"))
        XCTAssertTrue(r.canStart(repo: "~/dev/somewhere-else"))
    }

    func test_theSameRepoWrittenDifferentlyStillCounts() {
        let r = DevTaskRegistry(maxConcurrent: 3)
        r.start(label: "a", repo: "~/dev/vibe-voice")
        for spelling in ["~/dev/vibe-voice/",
                         (("~/dev/vibe-voice" as NSString).expandingTildeInPath)] {
            XCTAssertFalse(r.canStart(repo: spelling), spelling)
        }
    }

    func test_repoIsFreedWhenItsTaskEnds() {
        let r = DevTaskRegistry(maxConcurrent: 3)
        let t = r.start(label: "a", repo: "~/dev/vibe-voice")
        r.finish(t.id, ok: true, result: "done")
        XCTAssertTrue(r.canStart(repo: "~/dev/vibe-voice"))
    }

    func test_capacityIsEnforced() {
        let r = DevTaskRegistry(maxConcurrent: 2)
        r.start(label: "a", repo: "~/a")
        r.start(label: "b", repo: "~/b")
        XCTAssertEqual(r.rejectionFor(repo: "~/c"), .atCapacity(limit: 2))
    }

    func test_blockedIsItsOwnOutcomeNotAFailure() {
        let r = DevTaskRegistry()
        let t = r.start(label: "notion", repo: "~/a")
        r.finish(t.id, ok: false, result: "partial", deniedTools: ["mcp__notion__search"])
        XCTAssertEqual(r.task(t.id)?.status, .blocked)
        XCTAssertEqual(r.task(t.id)?.deniedTools, ["mcp__notion__search"])
    }

    func test_repeatedStepsCollapseAndHistoryIsBounded() {
        let r = DevTaskRegistry()
        let t = r.start(label: "a", repo: "~/a")
        r.addStep("Read Foo.swift", to: t.id)
        r.addStep("Read Foo.swift", to: t.id)
        XCTAssertEqual(r.task(t.id)?.steps.count, 1)

        for i in 0..<60 { r.addStep("step \(i)", to: t.id) }
        XCTAssertLessThanOrEqual(r.task(t.id)?.steps.count ?? 0, 40)
    }

    /// "Make it faster" has to land on the right conversation.
    func test_followUpResumesTheMostRecentRunningTask() {
        let base = Date()
        let r = DevTaskRegistry()
        r.start(label: "old", repo: "~/a", now: base)
        let newer = r.start(label: "new", repo: "~/b", now: base.addingTimeInterval(10))
        XCTAssertEqual(r.mostRecentResumable()?.id, newer.id)
    }

    func test_followUpFallsBackToAFinishedTaskThatHasASession() {
        let base = Date()
        let r = DevTaskRegistry()
        let t = r.start(label: "done", repo: "~/a", now: base)
        r.setSessionID("sess_abc", for: t.id)
        r.finish(t.id, ok: true, result: "ok", now: base.addingTimeInterval(5))
        XCTAssertEqual(r.mostRecentResumable()?.id, t.id)
    }

    func test_pruningKeepsRunningTasksAndTheNewestFinishedOnes() {
        let base = Date()
        let r = DevTaskRegistry(maxConcurrent: 10)
        let live = r.start(label: "live", repo: "~/live", now: base)
        for i in 0..<12 {
            let t = r.start(label: "t\(i)", repo: "~/r\(i)", now: base)
            r.finish(t.id, ok: true, result: "ok", now: base.addingTimeInterval(Double(i)))
        }
        r.pruneFinished(keeping: 5)
        XCTAssertEqual(r.finished.count, 5)
        XCTAssertNotNil(r.task(live.id), "a running task must never be pruned")
    }

    // MARK: - The queue

    private func request(_ what: String = "do the thing") -> DevTaskRequest {
        DevTaskRequest(instruction: what, permissionMode: "acceptEdits")
    }

    func test_aQueuedTaskIsNeitherRunningNorFinished() {
        let r = DevTaskRegistry()
        r.start(label: "first", repo: "~/a")
        let waiting = r.enqueue(label: "second", repo: "~/a", request: request())

        XCTAssertEqual(r.task(waiting.id)?.status, .queued)
        XCTAssertEqual(r.running.count, 1)
        XCTAssertEqual(r.queued.map(\.id), [waiting.id])
        XCTAssertTrue(r.finished.isEmpty, "queued is not an outcome")
    }

    /// The whole point: a second task for a busy repo waits instead of being turned away,
    /// and starts on its own the moment the first one ends.
    func test_theNextQueuedTaskStartsWhenTheRepoFrees() {
        let r = DevTaskRegistry()
        let first = r.start(label: "first", repo: "~/dev/vibe-voice")
        let second = r.enqueue(label: "second", repo: "~/dev/vibe-voice", request: request())

        XCTAssertNil(r.startNextQueued(), "the repo is still busy")

        r.finish(first.id, ok: true, result: "done")
        XCTAssertEqual(r.startNextQueued()?.id, second.id)
        XCTAssertEqual(r.task(second.id)?.status, .running)
        XCTAssertNil(r.startNextQueued(), "and now the repo is busy again")
    }

    /// One job per repo is still absolute — the queue may not smuggle a second one in.
    func test_theQueueNeverStartsTwoJobsInOneRepo() {
        let r = DevTaskRegistry(maxConcurrent: 3)
        r.start(label: "live", repo: "~/a")
        r.enqueue(label: "same repo", repo: "~/a", request: request())
        r.enqueue(label: "also same", repo: "~/a", request: request())

        XCTAssertNil(r.startNextQueued())
        XCTAssertEqual(r.running.count, 1)
    }

    /// A queued job for a free repo is not held up by one queued ahead of it whose repo
    /// is busy — the queue is an order, not a barrier.
    func test_aBlockedQueuedTaskDoesNotHoldUpTheOneBehindIt() {
        let r = DevTaskRegistry(maxConcurrent: 3)
        r.start(label: "live", repo: "~/a")
        r.enqueue(label: "blocked", repo: "~/a", request: request())
        let free = r.enqueue(label: "free", repo: "~/b", request: request())

        XCTAssertEqual(r.startNextQueued()?.id, free.id)
    }

    func test_capacityStillCapsWhatTheQueueMayStart() {
        let r = DevTaskRegistry(maxConcurrent: 2)
        r.start(label: "a", repo: "~/a")
        r.start(label: "b", repo: "~/b")
        r.enqueue(label: "c", repo: "~/c", request: request())

        XCTAssertNil(r.startNextQueued())
        XCTAssertEqual(r.rejectionFor(repo: "~/c"), .atCapacity(limit: 2))
    }

    func test_queuedTasksCanBeReorderedBeforeTheyRun() {
        let r = DevTaskRegistry()
        r.start(label: "live", repo: "~/a")
        let one = r.enqueue(label: "one", repo: "~/a", request: request())
        let two = r.enqueue(label: "two", repo: "~/a", request: request())
        let three = r.enqueue(label: "three", repo: "~/a", request: request())

        XCTAssertTrue(r.moveQueued(three.id, by: -1))
        XCTAssertEqual(r.queued.map(\.id), [one.id, three.id, two.id])
        XCTAssertEqual(r.queuePosition(three.id), 2)

        XCTAssertTrue(r.moveQueued(three.id, by: -1))
        XCTAssertEqual(r.queued.map(\.id), [three.id, one.id, two.id])

        XCTAssertFalse(r.moveQueued(three.id, by: -1), "already first")
        XCTAssertFalse(r.moveQueued(two.id, by: 1), "already last")
        XCTAssertEqual(r.queued.map(\.id), [three.id, one.id, two.id])
    }

    /// Reordering must not disturb what is running or what has already finished —
    /// the queue shares one array with both.
    func test_reorderingLeavesRunningAndFinishedTasksAlone() {
        let r = DevTaskRegistry(maxConcurrent: 3)
        let live = r.start(label: "live", repo: "~/a")
        let done = r.start(label: "done", repo: "~/b")
        r.finish(done.id, ok: true, result: "ok")
        let one = r.enqueue(label: "one", repo: "~/a", request: request())
        let two = r.enqueue(label: "two", repo: "~/a", request: request())

        r.moveQueued(from: 0, to: 2)

        XCTAssertEqual(r.queued.map(\.id), [two.id, one.id])
        XCTAssertEqual(r.task(live.id)?.status, .running)
        XCTAssertEqual(r.task(done.id)?.status, .finished)
    }

    /// Reordering decides what runs next, which is the only reason to do it.
    func test_theReorderedQueueIsTheOrderThingsRunIn() {
        let r = DevTaskRegistry()
        let live = r.start(label: "live", repo: "~/a")
        r.enqueue(label: "one", repo: "~/a", request: request())
        let two = r.enqueue(label: "two", repo: "~/a", request: request())
        r.moveQueued(two.id, by: -1)

        r.finish(live.id, ok: true, result: "ok")
        XCTAssertEqual(r.startNextQueued()?.id, two.id)
    }

    func test_aQueuedTaskCanBeDropped() {
        let r = DevTaskRegistry()
        let live = r.start(label: "live", repo: "~/a")
        let waiting = r.enqueue(label: "waiting", repo: "~/a", request: request())

        // Removed outright rather than filed as cancelled — it never ran. This asserted
        // the opposite until somebody dismissed a queued task and found a card left
        // behind in the finished list.
        r.cancel(waiting.id)
        XCTAssertNil(r.task(waiting.id))
        XCTAssertTrue(r.queued.isEmpty)

        r.finish(live.id, ok: true, result: "ok")
        XCTAssertNil(r.startNextQueued(), "a dropped task must not come back")
    }

    /// The instruction has to survive the wait, or the queue is a list of promises it
    /// has forgotten how to keep.
    func test_aQueuedTaskRemembersWhatItWasAskedToDo() {
        let r = DevTaskRegistry()
        r.start(label: "live", repo: "~/a")
        let waiting = r.enqueue(label: "waiting", repo: "~/a",
                                request: DevTaskRequest(instruction: "tighten the button spacing",
                                                        permissionMode: "bypassPermissions",
                                                        resumeTaskID: "T1"))
        XCTAssertEqual(r.task(waiting.id)?.request?.instruction, "tighten the button spacing")
        XCTAssertEqual(r.task(waiting.id)?.request?.permissionMode, "bypassPermissions")
        XCTAssertEqual(r.task(waiting.id)?.request?.resumeTaskID, "T1")
    }

    /// Elapsed time must mean "ran for", not "existed for" — a task that waited an hour
    /// and ran for ten seconds took ten seconds.
    func test_timeSpentWaitingIsNotCountedAsTimeSpentRunning() {
        let r = DevTaskRegistry()
        let live = r.start(label: "live", repo: "~/a", now: base)
        let waiting = r.enqueue(label: "waiting", repo: "~/a", request: request(), now: base)

        r.finish(live.id, ok: true, result: "ok", now: base.addingTimeInterval(3600))
        let started = r.startNextQueued(now: base.addingTimeInterval(3600))

        XCTAssertEqual(started?.id, waiting.id)
        XCTAssertEqual(r.task(waiting.id)?.elapsed(now: base.addingTimeInterval(3610)), 10)
        XCTAssertEqual(r.task(waiting.id)?.queuedAt, base)
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)
}

extension DevTaskRegistryTests {

    private func queuedRegistry() -> (DevTaskRegistry, DevTask) {
        let r = DevTaskRegistry(maxConcurrent: 3)
        let running = r.start(label: "first", repo: "~/a")
        _ = r.enqueue(label: "second", repo: "~/a",
                      request: DevTaskRequest(instruction: "x", permissionMode: "acceptEdits"))
        return (r, running)
    }

    func test_pauseStopsTheNextTaskFromStarting() {
        let (r, running) = queuedRegistry()
        r.pause()
        r.finish(running.id, ok: true, result: "done")
        XCTAssertNil(r.startNextQueued(), "paused queues start nothing")
        XCTAssertEqual(r.queued.count, 1, "and the task is still waiting, not dropped")
    }

    func test_resumeReleasesIt() {
        let (r, running) = queuedRegistry()
        r.pause()
        r.finish(running.id, ok: true, result: "done")
        XCTAssertNil(r.startNextQueued())
        r.resume()
        XCTAssertEqual(r.startNextQueued()?.label, "second")
    }

    /// Pause means "take on nothing more", not "abandon what is underway". Conflating
    /// the two would make it a destructive button nobody would risk pressing.
    func test_pauseNeverInterruptsSomethingAlreadyRunning() {
        let (r, running) = queuedRegistry()
        r.pause()
        XCTAssertEqual(r.task(running.id)?.status, .running)
        XCTAssertEqual(r.running.count, 1)
    }

    func test_theExplanationSaysWhatIsActuallyHappening() {
        let (r, running) = queuedRegistry()
        r.pause()
        XCTAssertTrue(r.pauseExplanation.contains("1 waiting"), r.pauseExplanation)
        r.finish(running.id, ok: true, result: "done")
        XCTAssertTrue(r.pauseExplanation.contains("1 task waiting"), r.pauseExplanation)
    }
}

extension DevTaskRegistryTests {

    /// Dismissing something that never ran should make it go away. It used to move to
    /// the finished list as "cancelled", which reads as a task that did something.
    func testCancellingAQueuedTaskRemovesItEntirely() {
        let r = DevTaskRegistry()
        let a = r.start(label: "first", repo: "x")
        let b = r.enqueue(label: "second", repo: "x", request: request())
        XCTAssertEqual(r.queued.count, 1)

        XCTAssertTrue(r.cancel(b.id))
        XCTAssertTrue(r.queued.isEmpty)
        XCTAssertTrue(r.finished.allSatisfy { $0.id != b.id }, "it should not be filed anywhere")
        XCTAssertNil(r.task(b.id))
        XCTAssertNotNil(r.task(a.id), "the running one is untouched")
    }

    /// A running task did work, so cancelling it keeps a row saying so.
    func testCancellingARunningTaskKeepsTheRecord() {
        let r = DevTaskRegistry()
        let a = r.start(label: "first", repo: "x")
        XCTAssertFalse(r.cancel(a.id))
        XCTAssertEqual(r.task(a.id)?.status, .cancelled)
        XCTAssertTrue(r.finished.contains { $0.id == a.id })
    }

    func testCancellingSomethingAlreadyFinishedDoesNothing() {
        let r = DevTaskRegistry()
        let a = r.start(label: "first", repo: "x")
        r.finish(a.id, ok: true, result: "done")
        XCTAssertFalse(r.cancel(a.id))
        XCTAssertEqual(r.task(a.id)?.status, .finished)
    }
}
