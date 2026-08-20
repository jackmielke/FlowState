import XCTest
@testable import VibeVoiceCore

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
}
