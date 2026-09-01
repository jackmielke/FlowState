import XCTest
@testable import FlowStateCore

/// Persistence, from both ends: what is written must come back, and what comes back must
/// not be quietly altered on the way in.
final class ConversationArchiveTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_755_000_000)

    private func entry(_ text: String,
                       _ speaker: TranscriptSpeaker = .user,
                       offset: TimeInterval = 0,
                       session: String = "chat-a") -> ConversationEntry {
        ConversationEntry(sessionID: session,
                          speaker: speaker,
                          text: text,
                          at: t0.addingTimeInterval(offset),
                          source: speaker == .user ? .realtimeAPI : .assistantStream)
    }

    private func summary(_ text: String, offset: TimeInterval = 0) -> ConversationSummary {
        ConversationSummary(sessionID: "chat-a",
                            text: text,
                            coveringFrom: t0,
                            coveringTo: t0.addingTimeInterval(offset),
                            entryCount: 4,
                            createdAt: t0.addingTimeInterval(offset),
                            generator: "test")
    }

    private func file(_ records: [Data?]) -> Data {
        records.compactMap { $0 }.reduce(into: Data()) { $0.append($1) }
    }

    // MARK: - Round trip

    func test_everythingWrittenComesBack() {
        let said = entry("fix the spacing on that button")
        let heard = entry("done — it's two points tighter now", .assistant, offset: 12)
        let recap = summary("You asked about the button spacing.", offset: 30)

        let archive = ConversationArchive.parse(file([
            ConversationArchive.line(for: said),
            ConversationArchive.line(for: heard),
            ConversationArchive.line(for: recap),
        ]))

        XCTAssertEqual(archive.entries, [said, heard])
        XCTAssertEqual(archive.summaries, [recap])
        XCTAssertEqual(archive.skippedLines, 0)
    }

    func test_theShapeOfAnUtteranceSurvivesTheDisk() {
        var line = entry("hello")
        line.audio = UtteranceAudio(startedAt: t0, duration: 1.5, sampleRate: 24_000,
                                    byteCount: 72_000, peakLevel: 0.42, averageLevel: 0.14)
        let back = ConversationArchive.parse(file([ConversationArchive.line(for: line)]))
        XCTAssertEqual(back.entries.first?.audio?.duration, 1.5)
        XCTAssertEqual(back.entries.first?.audio?.peakLevel, 0.42)
        XCTAssertEqual(back.entries.first, line)
    }

    func test_recordsComeBackInTheOrderTheyWereSaid() {
        let archive = ConversationArchive.parse(file([
            ConversationArchive.line(for: entry("third", offset: 30)),
            ConversationArchive.line(for: entry("first", offset: 0)),
            ConversationArchive.line(for: entry("second", offset: 15)),
        ]))
        XCTAssertEqual(archive.entries.map(\.text), ["first", "second", "third"])
    }

    // MARK: - Damage

    /// The app quitting mid-write leaves half a line. Losing a sentence is acceptable;
    /// losing the conversation it was in is not.
    func test_aTruncatedLastLineCostsOnlyThatLine() {
        var data = file([ConversationArchive.line(for: entry("kept", offset: 0)),
                         ConversationArchive.line(for: entry("also kept", offset: 5))])
        data.append(Data(#"{"kind":"entry","text":"half wri"#.utf8))

        let archive = ConversationArchive.parse(data)
        XCTAssertEqual(archive.entries.map(\.text), ["kept", "also kept"])
        XCTAssertEqual(archive.skippedLines, 1)
    }

    func test_recordsFromAFutureVersionAreSkippedNotFatal() {
        let data = file([ConversationArchive.line(for: entry("kept")),
                         Data("{\"kind\":\"something-new\",\"whatever\":1}\n".utf8)])
        let archive = ConversationArchive.parse(data)
        XCTAssertEqual(archive.entries.count, 1)
        XCTAssertEqual(archive.skippedLines, 1)
    }

    func test_blankLinesAreNotDamage() {
        let data = file([ConversationArchive.line(for: entry("kept")), Data("\n\n".utf8)])
        let archive = ConversationArchive.parse(data)
        XCTAssertEqual(archive.entries.count, 1)
        XCTAssertEqual(archive.skippedLines, 0)
    }

    func test_anEmptyFileIsAnEmptyConversationNotAnError() {
        XCTAssertTrue(ConversationArchive.parse(Data()).isEmpty)
    }

    // MARK: - Rebuilding the list from the files alone

    /// Deleting the index must cost nothing but the titles the user typed by hand.
    func test_theSessionListCanBeRebuiltFromATranscript() {
        let archive = ConversationArchive.Archive(
            entries: [entry("hey", offset: 0),
                      entry("can you fix the spacing on that button", offset: 4),
                      entry("done", .assistant, offset: 9),
                      ConversationEntry(sessionID: "chat-a", speaker: .system,
                                        text: "Live · session sess_1",
                                        at: t0.addingTimeInterval(1), source: .app)],
            summaries: [summary("recap", offset: 60)])

        let meta = ConversationArchive.meta(for: "chat-a",
                                            archive: archive,
                                            fallbackDate: t0,
                                            now: t0.addingTimeInterval(600))
        XCTAssertEqual(meta.id, "chat-a")
        XCTAssertEqual(meta.title, "Fix the spacing on that button")
        XCTAssertFalse(meta.titleIsCustom)
        XCTAssertEqual(meta.createdAt, t0)
        XCTAssertEqual(meta.updatedAt, t0.addingTimeInterval(60), "a summary is activity too")
        XCTAssertEqual(meta.entryCount, 3, "the app's own narration is not conversation")
    }

    // MARK: - Restoring into memory

    func test_restoringPutsAConversationBackWithoutRunningItThroughTheDoorAgain() {
        var privacy = TranscriptPrivacy()
        privacy.paused = true                 // nothing NEW may be recorded…
        let log = ConversationLog(privacy: privacy)

        let restored = log.restore(entries: [entry("said before the pause")],
                                   now: t0.addingTimeInterval(60))
        XCTAssertEqual(restored, 1, "…but history is not a new recording")
        XCTAssertEqual(log.entries.first?.text, "said before the pause")
        XCTAssertNil(log.append(sessionID: "chat-a", speaker: .user, text: "and this is refused",
                                source: .realtimeAPI))
    }

    func test_restoringTwiceDoesNotDuplicateAnything() {
        let log = ConversationLog()
        let said = [entry("one", offset: 0), entry("two", offset: 5)]
        let recap = [summary("recap", offset: 10)]

        let shortlyAfter = t0.addingTimeInterval(60)
        XCTAssertEqual(log.restore(entries: said, summaries: recap, now: shortlyAfter), 2)
        XCTAssertEqual(log.restore(entries: said, summaries: recap, now: shortlyAfter), 0)
        XCTAssertEqual(log.entries.count, 2)
        XCTAssertEqual(log.summaries.count, 1)
    }

    func test_restoredLinesAreStillSubjectToRetention() {
        var privacy = TranscriptPrivacy()
        privacy.retentionHours = 24
        let log = ConversationLog(privacy: privacy)

        let now = t0.addingTimeInterval(48 * 3600)
        let added = log.restore(entries: [entry("ancient", offset: 0),
                                          entry("recent", offset: 47 * 3600)],
                                now: now)
        XCTAssertEqual(added, 1)
        XCTAssertEqual(log.entries.map(\.text), ["recent"],
                       "a transcript past its window must not come back to life")
    }

    func test_restoredLinesLandInTimeOrderAlongsideLiveOnes() {
        let log = ConversationLog()
        log.append(sessionID: "chat-a", speaker: .user, text: "said now",
                   at: t0.addingTimeInterval(100), source: .realtimeAPI)
        log.restore(entries: [entry("said earlier", offset: 0)], now: t0.addingTimeInterval(200))
        XCTAssertEqual(log.entries.map(\.text), ["said earlier", "said now"])
    }

    func test_aRestoredConversationCanStillBeForgotten() {
        let log = ConversationLog()
        log.restore(entries: [entry("one", offset: 0), entry("two", offset: 5)],
                    summaries: [summary("recap", offset: 10)],
                    now: t0.addingTimeInterval(60))
        XCTAssertEqual(log.forget(session: "chat-a"), 2)
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertTrue(log.summaries.isEmpty)
    }

    // MARK: - Corrections

    func test_anEditRewritesTheLineItNamesAndNothingElse() {
        let a = entry("send it to jack at gmail")
        let b = entry("on it", .assistant, offset: 3)
        let fix = TranscriptEdit(sessionID: "chat-a", entryID: a.id,
                                 text: "send it to Jack",
                                 at: t0.addingTimeInterval(60))

        let parsed = ConversationArchive.parse(file([ConversationArchive.line(for: a),
                                                     ConversationArchive.line(for: b),
                                                     ConversationArchive.line(for: fix)]))
        XCTAssertEqual(parsed.entries.map(\.text), ["send it to Jack", "on it"])
        XCTAssertEqual(parsed.editCount, 1)
        XCTAssertEqual(parsed.skippedLines, 0, "a correction is not damage")
    }

    func test_anEditedLineKeepsItsPlaceInTheConversation() {
        let a = entry("first")
        let b = entry("second", .assistant, offset: 5)
        let fix = TranscriptEdit(sessionID: "chat-a", entryID: a.id, text: "first, corrected",
                                 at: t0.addingTimeInterval(900))

        let parsed = ConversationArchive.parse(file([ConversationArchive.line(for: a),
                                                     ConversationArchive.line(for: b),
                                                     ConversationArchive.line(for: fix)]))
        XCTAssertEqual(parsed.entries.map(\.text), ["first, corrected", "second"],
                       "correcting a line an hour later must not move it to an hour later")
        XCTAssertEqual(parsed.entries.first?.at, t0)
    }

    func test_theLastCorrectionWins() {
        let a = entry("one")
        let first = TranscriptEdit(sessionID: "chat-a", entryID: a.id, text: "two", at: t0)
        let second = TranscriptEdit(sessionID: "chat-a", entryID: a.id, text: "three", at: t0)

        let parsed = ConversationArchive.parse(file([ConversationArchive.line(for: a),
                                                     ConversationArchive.line(for: first),
                                                     ConversationArchive.line(for: second)]))
        XCTAssertEqual(parsed.entries.map(\.text), ["three"])
    }

    func test_aDeletedLineDoesNotComeBackAndTakesNothingWithIt() {
        let a = entry("delete this one")
        let b = entry("keep this one", .assistant, offset: 4)
        let gone = TranscriptEdit(sessionID: "chat-a", entryID: a.id, text: nil, at: t0)

        let parsed = ConversationArchive.parse(file([ConversationArchive.line(for: a),
                                                     ConversationArchive.line(for: b),
                                                     ConversationArchive.line(for: gone)]))
        XCTAssertEqual(parsed.entries.map(\.text), ["keep this one"])
        XCTAssertTrue(gone.isDeletion)
    }

    func test_deletionBeatsAnEarlierEditOfTheSameLine() {
        let a = entry("secret")
        let fix = TranscriptEdit(sessionID: "chat-a", entryID: a.id, text: "less secret", at: t0)
        let gone = TranscriptEdit(sessionID: "chat-a", entryID: a.id, text: nil, at: t0)

        let parsed = ConversationArchive.parse(file([ConversationArchive.line(for: a),
                                                     ConversationArchive.line(for: fix),
                                                     ConversationArchive.line(for: gone)]))
        XCTAssertTrue(parsed.entries.isEmpty, "asking for it to be gone means gone")
    }

    func test_aCorrectionForALineThatIsNotHereIsIgnoredRatherThanInvented() {
        let a = entry("still here")
        let orphan = TranscriptEdit(sessionID: "chat-a", entryID: UUID(),
                                    text: "resurrect me", at: t0)

        let parsed = ConversationArchive.parse(file([ConversationArchive.line(for: a),
                                                     ConversationArchive.line(for: orphan)]))
        XCTAssertEqual(parsed.entries.map(\.text), ["still here"])
    }

    /// The count the index shows has to agree with the transcript after corrections, or
    /// the switcher advertises lines that are no longer in the file.
    func test_deletedLinesDoNotCountTowardsTheSessionsLineCount() {
        let a = entry("one")
        let b = entry("two", .assistant, offset: 2)
        let gone = TranscriptEdit(sessionID: "chat-a", entryID: b.id, text: nil, at: t0)

        let parsed = ConversationArchive.parse(file([ConversationArchive.line(for: a),
                                                     ConversationArchive.line(for: b),
                                                     ConversationArchive.line(for: gone)]))
        let meta = ConversationArchive.meta(for: "chat-a", archive: parsed, fallbackDate: t0)
        XCTAssertEqual(meta.entryCount, 1)
    }
}
