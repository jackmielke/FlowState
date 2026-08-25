import XCTest
@testable import VibeVoiceCore

final class ConversationLogTests: XCTestCase {

    private func audio(duration: TimeInterval = 1.5, peak: Float = 0.4) -> UtteranceAudio {
        UtteranceAudio(startedAt: Date(),
                       duration: duration,
                       sampleRate: 24_000,
                       byteCount: Int(duration * 24_000 * 2),
                       peakLevel: peak,
                       averageLevel: peak / 3)
    }

    /// The two things everything downstream depends on: a line knows when it was said
    /// and which conversation it belongs to.
    func test_everyEntryCarriesItsSessionAndTimestamp() {
        let log = ConversationLog()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let e = log.append(sessionID: "sess_abc", speaker: .user, text: "hello",
                           at: when, source: .realtimeAPI)
        XCTAssertEqual(e?.sessionID, "sess_abc")
        XCTAssertEqual(e?.at, when)
        XCTAssertEqual(e?.source, .realtimeAPI)
    }

    func test_audioIsKeptAsMetadataAndNeverAsAClipUnlessAskedFor() {
        let log = ConversationLog()
        var withClip = audio()
        withClip.clipPath = "/tmp/should-not-survive.caf"

        let e = log.append(sessionID: "s", speaker: .user, text: "hi",
                           source: .realtimeAPI, audio: withClip)
        XCTAssertEqual(e?.audio?.duration, 1.5, "the shape of the utterance is kept")
        XCTAssertNil(e?.audio?.clipPath, "a path to real audio must not survive the default policy")
    }

    func test_turningOffAudioMetadataDropsItEntirely() {
        var privacy = TranscriptPrivacy()
        privacy.captureAudioMetadata = false
        let log = ConversationLog(privacy: privacy)

        let e = log.append(sessionID: "s", speaker: .user, text: "hi",
                           source: .realtimeAPI, audio: audio())
        XCTAssertNotNil(e)
        XCTAssertNil(e?.audio)
    }

    func test_pausedRecordsNothingAtAll() {
        var privacy = TranscriptPrivacy()
        privacy.paused = true
        let log = ConversationLog(privacy: privacy)

        for who in TranscriptSpeaker.allCases {
            XCTAssertNil(log.append(sessionID: "s", speaker: who, text: "x", source: .app), "\(who)")
        }
        XCTAssertTrue(log.entries.isEmpty)
    }

    func test_eachSideCanBeRefusedIndependently() {
        var privacy = TranscriptPrivacy()
        privacy.captureUserSpeech = false
        let log = ConversationLog(privacy: privacy)

        XCTAssertNil(log.append(sessionID: "s", speaker: .user, text: "mine", source: .realtimeAPI))
        XCTAssertNotNil(log.append(sessionID: "s", speaker: .assistant, text: "yours",
                                   source: .assistantStream))
    }

    /// System notes are off by default. They are the app talking to itself, and letting
    /// them in is what turns a summary of a conversation into a changelog.
    func test_systemNotesAreNotRecordedByDefault() {
        let log = ConversationLog()
        XCTAssertNil(log.append(sessionID: "s", speaker: .system, text: "tool ran", source: .app))
    }

    func test_secretsAreRewrittenBeforeStorage() {
        let log = ConversationLog()
        let e = log.append(sessionID: "s", speaker: .user,
                           text: "the key is sk-proj-AbCdEf0123456789xyz, mail me at jack@example.com",
                           source: .realtimeAPI)
        XCTAssertEqual(e?.redacted, true)
        XCTAssertFalse(e?.text.contains("sk-proj-AbCdEf") ?? true)
        XCTAssertFalse(e?.text.contains("@example.com") ?? true)
        XCTAssertTrue(e?.text.contains("[api-key]") ?? false)
        XCTAssertTrue(e?.text.contains("[email]") ?? false)
    }

    /// Over-redacting a voice transcript makes it useless, which is its own failure.
    func test_ordinaryNumbersAreLeftAlone() {
        let log = ConversationLog()
        let e = log.append(sessionID: "s", speaker: .user,
                           text: "run it on port 8080 and give me 3 of them",
                           source: .realtimeAPI)
        XCTAssertEqual(e?.redacted, false)
        XCTAssertEqual(e?.text, "run it on port 8080 and give me 3 of them")
    }

    func test_redactionCanBeTurnedOff() {
        var privacy = TranscriptPrivacy()
        privacy.redactSensitiveText = false
        let log = ConversationLog(privacy: privacy)
        let e = log.append(sessionID: "s", speaker: .user, text: "jack@example.com",
                           source: .realtimeAPI)
        XCTAssertEqual(e?.text, "jack@example.com")
        XCTAssertEqual(e?.redacted, false)
    }

    func test_emptyAndWhitespaceOnlyLinesAreNotRecorded() {
        let log = ConversationLog()
        XCTAssertNil(log.append(sessionID: "s", speaker: .user, text: "   \n ", source: .realtimeAPI))
    }

    /// Retention has to bite on what is ALREADY held, not only on what comes next —
    /// otherwise turning the window down does nothing until the next launch.
    func test_purgeDeletesWhatIsAlreadyPastTheWindow() {
        var privacy = TranscriptPrivacy()
        privacy.retentionHours = 24
        let log = ConversationLog(privacy: privacy)

        let now = Date()
        log.append(sessionID: "s", speaker: .user, text: "old",
                   at: now.addingTimeInterval(-48 * 3600), source: .realtimeAPI)
        log.append(sessionID: "s", speaker: .user, text: "recent",
                   at: now.addingTimeInterval(-3600), source: .realtimeAPI)

        XCTAssertEqual(log.purgeExpired(now: now), 1)
        XCTAssertEqual(log.entries.map(\.text), ["recent"])
    }

    func test_retentionOfZeroMeansForever() {
        var privacy = TranscriptPrivacy()
        privacy.retentionHours = 0
        let log = ConversationLog(privacy: privacy)
        log.append(sessionID: "s", speaker: .user, text: "ancient",
                   at: Date(timeIntervalSince1970: 0), source: .realtimeAPI)
        XCTAssertEqual(log.purgeExpired(), 0)
        XCTAssertEqual(log.entries.count, 1)
    }

    func test_forgettingOneSessionLeavesTheOthers() {
        let log = ConversationLog()
        log.append(sessionID: "a", speaker: .user, text: "one", source: .realtimeAPI)
        log.append(sessionID: "b", speaker: .user, text: "two", source: .realtimeAPI)
        log.append(summary: ConversationSummary(sessionID: "a", text: "s", coveringFrom: Date(),
                                                coveringTo: Date(), entryCount: 1,
                                                generator: "test"))

        XCTAssertEqual(log.forget(session: "a"), 1)
        XCTAssertEqual(log.entries.map(\.sessionID), ["b"])
        XCTAssertTrue(log.summaries.isEmpty, "a session's summaries go with it")
    }

    func test_memoryIsBounded() {
        let log = ConversationLog(maxEntries: 20)
        for i in 0..<100 {
            log.append(sessionID: "s", speaker: .user, text: "line \(i)", source: .realtimeAPI)
        }
        XCTAssertEqual(log.entries.count, 20)
        XCTAssertEqual(log.entries.last?.text, "line 99", "the newest lines are the ones kept")
    }

    /// A summary must be built from the conversation, not from the app's own narration.
    func test_summaryInputExcludesSystemLinesAndAlreadyCoveredOnes() {
        var privacy = TranscriptPrivacy()
        privacy.captureSystemNotes = true
        let log = ConversationLog(privacy: privacy)

        let base = Date()
        log.append(sessionID: "s", speaker: .user, text: "before",
                   at: base, source: .realtimeAPI)
        log.append(sessionID: "s", speaker: .system, text: "tool ran",
                   at: base.addingTimeInterval(10), source: .app)
        log.append(sessionID: "s", speaker: .assistant, text: "after",
                   at: base.addingTimeInterval(20), source: .assistantStream)

        let fresh = log.conversation(inSession: "s", after: base)
        XCTAssertEqual(fresh.map(\.text), ["after"])
    }

    // MARK: - Pinned conversations outlive retention

    func test_retentionSkipsAPinnedConversation() {
        var privacy = TranscriptPrivacy()
        privacy.retentionHours = 24
        let log = ConversationLog(privacy: privacy)
        log.pinnedSessions = ["chat-keep"]

        let then = Date(timeIntervalSince1970: 1_700_000_000)
        log.append(sessionID: "chat-keep", speaker: .user, text: "worth keeping",
                   at: then, source: .realtimeAPI)
        log.append(sessionID: "chat-other", speaker: .user, text: "ordinary",
                   at: then, source: .realtimeAPI)

        let dropped = log.purgeExpired(now: then.addingTimeInterval(72 * 3600))
        XCTAssertEqual(dropped, 1)
        XCTAssertEqual(log.entries.map(\.text), ["worth keeping"])
    }

    func test_aPinnedConversationComesBackOffDiskEvenPastItsWindow() {
        var privacy = TranscriptPrivacy()
        privacy.retentionHours = 1
        let log = ConversationLog(privacy: privacy)
        log.pinnedSessions = ["chat-keep"]

        let then = Date(timeIntervalSince1970: 1_700_000_000)
        let old = ConversationEntry(sessionID: "chat-keep", speaker: .user,
                                    text: "from last week", at: then, source: .realtimeAPI)
        XCTAssertEqual(log.restore(entries: [old], now: then.addingTimeInterval(7 * 24 * 3600)), 1)
    }

    // MARK: - Correcting a line

    func test_editingALineRewritesItInPlace() {
        let log = ConversationLog()
        let e = log.append(sessionID: "s", speaker: .user, text: "sen it to jak",
                           source: .realtimeAPI)!
        let fixed = log.edit(entryID: e.id, to: "send it to Jack")
        XCTAssertEqual(fixed?.text, "send it to Jack")
        XCTAssertEqual(log.entries.count, 1, "an edit is not a second line")
        XCTAssertEqual(log.entries.first?.at, e.at, "and it does not move in the conversation")
    }

    func test_anEditIsRedactedLikeAnythingElseWritten() {
        let log = ConversationLog()
        let e = log.append(sessionID: "s", speaker: .user, text: "hello",
                           source: .realtimeAPI)!
        let fixed = log.edit(entryID: e.id, to: "the key is sk-live-abcdefghijklmno")
        XCTAssertEqual(fixed?.text.contains("[api-key]"), true)
        XCTAssertEqual(fixed?.redacted, true)
    }

    func test_anEditWorksWhileRecordingIsPaused() {
        var privacy = TranscriptPrivacy()
        let log = ConversationLog(privacy: privacy)
        let e = log.append(sessionID: "s", speaker: .user, text: "wrong", source: .realtimeAPI)!

        privacy.paused = true
        log.privacy = privacy
        XCTAssertEqual(log.edit(entryID: e.id, to: "right")?.text, "right",
                       "refusing would leave a line on screen the user has just corrected")
    }

    func test_anEmptyEditIsRefusedRatherThanBlankingTheLine() {
        let log = ConversationLog()
        let e = log.append(sessionID: "s", speaker: .user, text: "something", source: .realtimeAPI)!
        XCTAssertNil(log.edit(entryID: e.id, to: "   "))
        XCTAssertEqual(log.entries.first?.text, "something")
    }

    func test_removingOneLineLeavesTheRest() {
        let log = ConversationLog()
        let a = log.append(sessionID: "s", speaker: .user, text: "one", source: .realtimeAPI)!
        log.append(sessionID: "s", speaker: .assistant, text: "two", source: .assistantStream)
        XCTAssertEqual(log.remove(entryID: a.id)?.text, "one")
        XCTAssertEqual(log.entries.map(\.text), ["two"])
        XCTAssertNil(log.remove(entryID: a.id), "and it is gone for good")
    }
}
