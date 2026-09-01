import XCTest
@testable import FlowStateCore

/// A placeholder that is never filled in is invisible to everything except the person
/// looking at it. These are the rules that make it visible to the app instead.
final class PendingTranscriptsTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_755_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // MARK: - The happy path

    func test_openedThenCommittedLeavesNothingBehind() {
        let led = PendingTranscripts()
        let id = UUID()
        led.open(id: id, label: "user transcript", at: t(0), now: t(0))
        XCTAssertTrue(led.isPending(id))
        XCTAssertEqual(led.count, 1)

        XCTAssertTrue(led.commit(id: id))
        XCTAssertTrue(led.isEmpty)
        XCTAssertEqual(led.abandonedCount, 0)
        // And it is no longer overdue however long we wait.
        XCTAssertTrue(led.takeOverdue(now: t(600), timeout: 12).isEmpty)
    }

    func test_committingTwiceIsReported() {
        let led = PendingTranscripts()
        let id = UUID()
        led.open(id: id, label: "user transcript", at: t(0), now: t(0))
        XCTAssertTrue(led.commit(id: id))
        // The second commit is the caller writing into a row that is no longer waiting —
        // which is exactly the thing it needs to be told about.
        XCTAssertFalse(led.commit(id: id))
    }

    // MARK: - Queued and never committed

    func test_anUpdateThatNeverArrivesIsReportedOnceItsDeadlinePasses() {
        let led = PendingTranscripts()
        let id = UUID()
        led.open(id: id, label: "user transcript", at: t(0), now: t(0))

        // Still within its deadline: not a fault yet, just slow.
        XCTAssertTrue(led.takeOverdue(now: t(11), timeout: 12).isEmpty)
        XCTAssertEqual(led.count, 1)

        let stale = led.takeOverdue(now: t(13), timeout: 12)
        XCTAssertEqual(stale.map(\.id), [id])
        XCTAssertEqual(stale.first?.label, "user transcript")
        XCTAssertEqual(stale.first?.waited(t(13)), 13)
        XCTAssertEqual(led.abandonedCount, 1)
    }

    func test_aStuckUpdateIsReportedOnceRatherThanEverySecond() {
        let led = PendingTranscripts()
        led.open(id: UUID(), label: "user transcript", at: t(0), now: t(0))

        XCTAssertEqual(led.takeOverdue(now: t(20), timeout: 12).count, 1)
        // The watchdog ticks again a second later and must not say it again.
        XCTAssertEqual(led.takeOverdue(now: t(21), timeout: 12).count, 0)
        XCTAssertEqual(led.abandonedCount, 1)
    }

    func test_overdueIsReportedOldestFirst() {
        let led = PendingTranscripts()
        let first = UUID(), second = UUID()
        led.open(id: first, label: "one", at: t(0), now: t(0))
        led.open(id: second, label: "two", at: t(4), now: t(4))
        XCTAssertEqual(led.takeOverdue(now: t(30), timeout: 12).map(\.id), [first, second])
    }

    // MARK: - The ground moving

    func test_disconnectingStrandsEverythingStillOpen() {
        let led = PendingTranscripts()
        led.open(id: UUID(), label: "one", at: t(0), now: t(0))
        led.open(id: UUID(), label: "two", at: t(1), now: t(1))

        XCTAssertEqual(led.takeAll().count, 2)
        XCTAssertTrue(led.isEmpty)
        XCTAssertEqual(led.abandonedCount, 2)
    }

    func test_abandoningOneReturnsWhatWasWaiting() {
        let led = PendingTranscripts()
        let id = UUID()
        led.open(id: id, label: "user transcript", at: t(3), now: t(5))

        let gone = led.abandon(id: id)
        XCTAssertEqual(gone?.at, t(3))
        XCTAssertEqual(gone?.openedAt, t(5))
        XCTAssertEqual(led.abandonedCount, 1)
        // Abandoning something that was never open is not an error and is not counted.
        XCTAssertNil(led.abandon(id: UUID()))
        XCTAssertEqual(led.abandonedCount, 1)
    }

    // MARK: - Reporting

    func test_longestWaitIsTheOldestOutstandingUpdate() {
        let led = PendingTranscripts()
        XCTAssertNil(led.longestWait(now: t(0)))
        led.open(id: UUID(), label: "one", at: t(0), now: t(2))
        led.open(id: UUID(), label: "two", at: t(0), now: t(8))
        XCTAssertEqual(led.longestWait(now: t(10)), 8)
    }
}
