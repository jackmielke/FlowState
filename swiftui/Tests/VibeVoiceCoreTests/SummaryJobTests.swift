import XCTest
@testable import VibeVoiceCore

final class SummaryJobTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// A log with `count` alternating user/assistant lines, one every 30 seconds.
    private func populated(_ count: Int, session: String = "s") -> ConversationLog {
        let log = ConversationLog()
        for i in 0..<count {
            log.append(sessionID: session,
                       speaker: i.isMultiple(of: 2) ? .user : .assistant,
                       text: "line number \(i) with enough words to look like speech",
                       at: base.addingTimeInterval(Double(i) * 30),
                       source: i.isMultiple(of: 2) ? .realtimeAPI : .assistantStream)
        }
        return log
    }

    func test_nothingIsDueBeforeThereIsAnythingToSayAboutIt() {
        let job = SummaryJob(policy: SummaryPolicy(everyNEntries: 6, minimumEntries: 4))
        job.begin(session: "s", now: base)
        XCTAssertNil(job.nextDigest(from: populated(3), now: base.addingTimeInterval(60)))
    }

    func test_dueOnceEnoughTurnsHavePiledUp() {
        let job = SummaryJob(policy: SummaryPolicy(everyNEntries: 6, everySeconds: 3600,
                                                   minimumEntries: 4))
        job.begin(session: "s", now: base)
        let digest = job.nextDigest(from: populated(6), now: base.addingTimeInterval(60))
        XCTAssertEqual(digest?.entries.count, 6)
        XCTAssertEqual(digest?.sessionID, "s")
    }

    func test_dueOnTimeEvenWhenTheCountIsLow() {
        let job = SummaryJob(policy: SummaryPolicy(everyNEntries: 50, everySeconds: 300,
                                                   minimumEntries: 4))
        job.begin(session: "s", now: base)
        XCTAssertNil(job.nextDigest(from: populated(5), now: base.addingTimeInterval(60)))
        XCTAssertNotNil(job.nextDigest(from: populated(5), now: base.addingTimeInterval(400)))
    }

    /// The bug this type exists to prevent: two summaries covering the same lines,
    /// because the first one had not finished when the second tick came round.
    func test_aRunInFlightBlocksASecondOne() {
        let job = SummaryJob(policy: SummaryPolicy(everyNEntries: 4, minimumEntries: 4))
        job.begin(session: "s", now: base)
        let log = populated(8)
        XCTAssertNotNil(job.nextDigest(from: log, now: base.addingTimeInterval(300)))
        XCTAssertNil(job.nextDigest(from: log, now: base.addingTimeInterval(301)),
                     "a second summariser must not start over the same window")
    }

    func test_theNextSummaryStartsWhereTheLastOneStopped() {
        let job = SummaryJob(policy: SummaryPolicy(everyNEntries: 4, minimumEntries: 4))
        job.begin(session: "s", now: base)

        let log = populated(8)
        let first = job.nextDigest(from: log, now: base.addingTimeInterval(300))!
        _ = job.complete(first, text: "…", generator: "test", now: base.addingTimeInterval(310))

        // Four more lines, after everything the first summary covered.
        for i in 8..<12 {
            log.append(sessionID: "s",
                       speaker: i.isMultiple(of: 2) ? .user : .assistant,
                       text: "later line \(i) said out loud",
                       at: base.addingTimeInterval(Double(i) * 30),
                       source: .realtimeAPI)
        }

        let second = job.nextDigest(from: log, now: base.addingTimeInterval(700))
        XCTAssertEqual(second?.entries.count, 4)
        XCTAssertTrue(second?.entries.allSatisfy { $0.at > first.to } ?? false,
                      "no line may be summarised twice")
    }

    func test_theSecondSummaryIsGivenTheFirstForContinuity() {
        let job = SummaryJob(policy: SummaryPolicy(everyNEntries: 4, minimumEntries: 4))
        job.begin(session: "s", now: base)
        let log = populated(8)
        let first = job.nextDigest(from: log, now: base.addingTimeInterval(300))!
        let summary = job.complete(first, text: "they talked about orbs",
                                   generator: "test", now: base.addingTimeInterval(310))
        log.append(summary: summary)

        for i in 8..<12 {
            log.append(sessionID: "s", speaker: .user, text: "later line \(i)",
                       at: base.addingTimeInterval(Double(i) * 30), source: .realtimeAPI)
        }
        let second = job.nextDigest(from: log, now: base.addingTimeInterval(700))
        XCTAssertEqual(second?.previousSummary, "they talked about orbs")
        XCTAssertTrue(second?.prompt.contains("they talked about orbs") ?? false)
    }

    func test_nothingIsSummarisedOverTheTopOfALiveTurn() {
        let job = SummaryJob(policy: SummaryPolicy(everyNEntries: 4, minimumEntries: 4))
        job.begin(session: "s", now: base)
        let log = populated(8)
        XCTAssertNil(job.nextDigest(from: log, now: base.addingTimeInterval(300), busy: true))
        XCTAssertNotNil(job.nextDigest(from: log, now: base.addingTimeInterval(300), busy: false))
    }

    /// "Summarise what we just talked about" skips the cadence, but not the check that
    /// there is anything worth summarising.
    func test_forceSkipsTheCadenceButNotTheFloor() {
        let job = SummaryJob(policy: SummaryPolicy(everyNEntries: 50, everySeconds: 3600,
                                                   minimumEntries: 4))
        job.begin(session: "s", now: base)
        XCTAssertNotNil(job.nextDigest(from: populated(5), now: base, busy: true, force: true))

        let idle = SummaryJob(policy: SummaryPolicy(minimumEntries: 4))
        idle.begin(session: "s", now: base)
        XCTAssertNil(idle.nextDigest(from: populated(2), now: base, force: true))
    }

    func test_disabledMeansNoScheduledSummariesButForceStillWorks() {
        let job = SummaryJob(policy: SummaryPolicy(enabled: false, everyNEntries: 4,
                                                   minimumEntries: 4))
        job.begin(session: "s", now: base)
        XCTAssertNil(job.nextDigest(from: populated(8), now: base.addingTimeInterval(300)))
        XCTAssertNotNil(job.nextDigest(from: populated(8), now: base.addingTimeInterval(300),
                                       force: true))
    }

    func test_oneSummaryIsCappedInSize() {
        let job = SummaryJob(policy: SummaryPolicy(everyNEntries: 4, minimumEntries: 4,
                                                   maxEntriesPerSummary: 10))
        job.begin(session: "s", now: base)
        let digest = job.nextDigest(from: populated(80), now: base.addingTimeInterval(3000))
        XCTAssertEqual(digest?.entries.count, 10)
        XCTAssertEqual(digest?.entries.last?.text.contains("line number 79"), true,
                       "the most recent turns are the ones summarised")
    }

    /// A run that straddles a reconnect must not mark the NEW session's opening lines as
    /// already covered.
    func test_aRunThatOutlivesItsSessionDoesNotAdvanceTheNewOne() {
        let job = SummaryJob(policy: SummaryPolicy(everyNEntries: 4, minimumEntries: 4))
        job.begin(session: "old", now: base)
        let old = populated(8, session: "old")
        let digest = job.nextDigest(from: old, now: base.addingTimeInterval(300))!

        job.begin(session: "new", now: base.addingTimeInterval(400))
        _ = job.complete(digest, text: "…", generator: "test", now: base.addingTimeInterval(410))

        XCTAssertEqual(job.coveredThrough, .distantPast)
    }

    func test_abandoningLeavesTheWindowUncovered() {
        let job = SummaryJob(policy: SummaryPolicy(everyNEntries: 4, minimumEntries: 4))
        job.begin(session: "s", now: base)
        let log = populated(8)
        _ = job.nextDigest(from: log, now: base.addingTimeInterval(300))
        job.abandon(now: base.addingTimeInterval(310))

        XCTAssertEqual(job.coveredThrough, .distantPast)
        XCTAssertFalse(job.isRunning)

        // Not immediately, though. The cadence is count-OR-time, and this window already
        // meets the count, so without an explicit backoff a summariser that keeps
        // failing would be re-run on every single tick.
        XCTAssertNil(job.nextDigest(from: log, now: base.addingTimeInterval(311)))
        XCTAssertNotNil(job.nextDigest(from: log,
                                       now: base.addingTimeInterval(310 + SummaryJob.retryBackoff)),
                        "the same lines are still owed a summary once the backoff is up")
    }

    /// A force is the user asking. It does not wait out a backoff.
    func test_backoffDoesNotBlockAnExplicitRequest() {
        let job = SummaryJob(policy: SummaryPolicy(everyNEntries: 4, minimumEntries: 4))
        job.begin(session: "s", now: base)
        let log = populated(8)
        _ = job.nextDigest(from: log, now: base.addingTimeInterval(300))
        job.abandon(now: base.addingTimeInterval(310))
        XCTAssertNotNil(job.nextDigest(from: log, now: base.addingTimeInterval(311), force: true))
    }

    func test_thePromptCarriesBothSidesWithTheirTimes() {
        let job = SummaryJob(policy: SummaryPolicy(everyNEntries: 4, minimumEntries: 4))
        job.begin(session: "s", now: base)
        let prompt = job.nextDigest(from: populated(6), now: base.addingTimeInterval(300))!.prompt
        XCTAssertTrue(prompt.contains("User: "))
        XCTAssertTrue(prompt.contains("Assistant: "))
        XCTAssertTrue(prompt.contains("Three sentences at most"))
    }

    func test_theOfflineSummariserSaysSomethingAboutBothSides() async {
        let job = SummaryJob(policy: SummaryPolicy(everyNEntries: 4, minimumEntries: 4))
        job.begin(session: "s", now: base)
        let log = ConversationLog()
        log.append(sessionID: "s", speaker: .user,
                   text: "can you make the orb pulse when the assistant is talking",
                   at: base, source: .realtimeAPI)
        log.append(sessionID: "s", speaker: .assistant, text: "On it.",
                   at: base.addingTimeInterval(5), source: .assistantStream)
        log.append(sessionID: "s", speaker: .user,
                   text: "and then push the whole thing to the release branch please",
                   at: base.addingTimeInterval(60), source: .realtimeAPI)
        log.append(sessionID: "s", speaker: .assistant,
                   text: "Pushed it. The build is green.",
                   at: base.addingTimeInterval(90), source: .assistantStream)

        let digest = job.nextDigest(from: log, now: base.addingTimeInterval(300), force: true)!
        let text = await ExtractiveSummarizer().summarize(digest)

        let summary = try? XCTUnwrap(text)
        XCTAssertTrue(summary?.contains("orb") ?? false, summary ?? "nil")
        XCTAssertTrue(summary?.contains("Pushed it") ?? false, summary ?? "nil")
        XCTAssertTrue(summary?.contains("4 turns") ?? false, summary ?? "nil")
    }

    // MARK: - The Summary button

    /// The button summarises the CONVERSATION, not the uncovered tail of it. Somebody
    /// asking "what did we just do?" after four rolling summaries wants all of it.
    func test_aSessionRecapCoversTheWholeSessionNotJustTheUncoveredPart() {
        let job = SummaryJob(policy: SummaryPolicy(everyNEntries: 4, minimumEntries: 4))
        job.begin(session: "s", now: base)
        let log = populated(10)

        // Cover the first stretch the ordinary way.
        let rolling = job.nextDigest(from: log, now: base.addingTimeInterval(300))!
        _ = job.complete(rolling, text: "earlier", generator: "t")

        let recap = job.sessionDigest("s", from: log)
        XCTAssertEqual(recap?.entries.count, 10)
        XCTAssertEqual(recap?.from, base)
        XCTAssertNil(recap?.previousSummary,
                     "a recap is the whole story, so nothing may tell it not to repeat the start")
    }

    /// The case the button exists for: the socket is gone, `sessionID` is nil, and the
    /// user asks what just happened.
    func test_aSessionRecapWorksAfterTheSessionHasEnded() {
        let job = SummaryJob()
        job.begin(session: "s", now: base)
        let log = populated(8)
        job.end()

        XCTAssertNil(job.nextDigest(from: log, now: base.addingTimeInterval(600), force: true),
                     "the scheduler has no session to work on once it has ended")
        XCTAssertEqual(job.sessionDigest("s", from: log)?.entries.count, 8)
    }

    func test_aSessionRecapStillRefusesToSummariseOneLine() {
        let job = SummaryJob()
        XCTAssertNil(job.sessionDigest("s", from: populated(1)))
        XCTAssertNotNil(job.sessionDigest("s", from: populated(2)))
    }

    func test_aSessionRecapIsNotStartedOnTopOfARunningOne() {
        let job = SummaryJob()
        job.begin(session: "s", now: base)
        let log = populated(8)
        XCTAssertNotNil(job.sessionDigest("s", from: log))
        XCTAssertNil(job.sessionDigest("s", from: log), "isRunning is held across the call")
    }

    /// A recap of the live session marks its ground covered, so the next rolling summary
    /// does not immediately say the same thing again.
    func test_aRecapOfTheLiveSessionAdvancesTheCoveredWindow() {
        let job = SummaryJob(policy: SummaryPolicy(everyNEntries: 4, minimumEntries: 4))
        job.begin(session: "s", now: base)
        let log = populated(8)

        let recap = job.sessionDigest("s", from: log)!
        _ = job.complete(recap, text: "all of it", generator: "t", now: base.addingTimeInterval(300))

        XCTAssertNil(job.nextDigest(from: log, now: base.addingTimeInterval(301)))
    }

    /// …but a recap of a DIFFERENT (older) session must not silence the live one.
    func test_aRecapOfAnOlderSessionLeavesTheLiveWindowAlone() {
        let job = SummaryJob(policy: SummaryPolicy(everyNEntries: 4, minimumEntries: 4))
        let log = ConversationLog()
        for i in 0..<6 {
            log.append(sessionID: "old", speaker: .user, text: "old line \(i)",
                       at: base.addingTimeInterval(Double(i)), source: .realtimeAPI)
        }
        for i in 0..<6 {
            log.append(sessionID: "live", speaker: .user, text: "live line \(i)",
                       at: base.addingTimeInterval(1000 + Double(i)), source: .realtimeAPI)
        }
        job.begin(session: "live", now: base)

        let recap = job.sessionDigest("old", from: log)!
        _ = job.complete(recap, text: "yesterday", generator: "t", now: base.addingTimeInterval(2000))

        XCTAssertNotNil(job.nextDigest(from: log, now: base.addingTimeInterval(2001)))
    }

    func test_theOfflineSummariserInventsNothingFromNothing() async {
        let empty = SummaryDigest(sessionID: "s", entries: [], previousSummary: nil,
                                  from: base, to: base, prompt: "")
        let out = await ExtractiveSummarizer().summarize(empty)
        XCTAssertNil(out)
    }
}
