import XCTest
@testable import VibeVoiceCore

/// The rules that decide whether somebody's transcript is still there tomorrow.
///
/// Every one of these is a way to lose a conversation the user expected to keep, which
/// is why they are decided in Core with no disk anywhere near them: the failure mode of
/// a retention bug is silent and permanent.
final class TranscriptRetentionTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_755_000_000)

    private func meta(_ id: String,
                      minutesAgo: Double,
                      pinned: Bool = false,
                      entries: Int = 4) -> SessionMeta {
        SessionMeta(id: id,
                    title: id,
                    createdAt: t0.addingTimeInterval(-minutesAgo * 60),
                    updatedAt: t0.addingTimeInterval(-minutesAgo * 60),
                    entryCount: entries,
                    pinned: pinned)
    }

    // MARK: - Keeping only the newest N

    func test_keepEverythingTrimsNothing() {
        let policy = TranscriptRetention(mode: .keepEverything, keepLast: 1)
        let sessions = (1...9).map { meta("chat-\($0)", minutesAgo: Double($0)) }
        XCTAssertTrue(policy.sessionsToTrim(sessions).isEmpty,
                      "the mode called Keep everything must keep everything")
    }

    func test_keepLastDropsTheOldestOnly() {
        let policy = TranscriptRetention(mode: .keepLast, keepLast: 2)
        let sessions = [meta("newest", minutesAgo: 1),
                        meta("middle", minutesAgo: 5),
                        meta("oldest", minutesAgo: 90)]
        XCTAssertEqual(policy.sessionsToTrim(sessions), ["oldest"])
    }

    func test_pinnedConversationsAreNeverTrimmedAndNeverCountAgainstTheLimit() {
        let policy = TranscriptRetention(mode: .keepLast, keepLast: 2)
        let sessions = [meta("newest", minutesAgo: 1),
                        meta("locked", minutesAgo: 10_000, pinned: true),
                        meta("second", minutesAgo: 5),
                        meta("third", minutesAgo: 50)]

        let doomed = policy.sessionsToTrim(sessions)
        XCTAssertFalse(doomed.contains("locked"), "a pin is the whole point")
        XCTAssertEqual(doomed, ["third"],
                       "the pinned one must not use up one of the two places either")
    }

    func test_theConversationOnScreenIsNeverTrimmed() {
        let policy = TranscriptRetention(mode: .keepLast, keepLast: 1)
        let sessions = [meta("newest", minutesAgo: 1), meta("open", minutesAgo: 900)]
        XCTAssertEqual(policy.sessionsToTrim(sessions, current: "open"), [],
                       "deleting what somebody is reading is not retention")
    }

    func test_theLimitCannotBeSetToZero() {
        XCTAssertEqual(TranscriptRetention(keepLast: 0).keepLast, 1)
        XCTAssertEqual(TranscriptRetention(keepLast: -4).keepLast, 1)
        XCTAssertEqual(TranscriptRetention(keepLast: 9_999).keepLast, 200)
    }

    // MARK: - Writing only when asked

    func test_manualSaveWritesNothingUnlessPinned() {
        let manual = TranscriptRetention(mode: .manualSave)
        XCTAssertFalse(manual.autosaves(pinned: false))
        XCTAssertTrue(manual.autosaves(pinned: true),
                      "a lock that did not survive quitting would be a lie")

        for mode in [TranscriptRetention.Mode.keepEverything, .keepLast] {
            XCTAssertTrue(TranscriptRetention(mode: mode).autosaves(pinned: false), "\(mode)")
        }
    }

    // MARK: - Pins in the catalogue

    func test_pinningSurvivesTheIndexBeingWrittenAndReadBack() throws {
        let catalog = SessionCatalog([meta("chat-a", minutesAgo: 3)])
        XCTAssertNotNil(catalog.setPinned(true, for: "chat-a", now: t0))
        XCTAssertEqual(catalog.pinnedIDs, ["chat-a"])

        let data = try ConversationArchive.encoder().encode(catalog.recents)
        let back = try ConversationArchive.decoder().decode([SessionMeta].self, from: data)
        XCTAssertEqual(back.first?.pinned, true)
        XCTAssertEqual(back.first?.pinnedAt, t0)
    }

    /// The index written by every build before pins existed has no `pinned` key. It is
    /// read with `try?` as one array, so a strict decoder would throw away every custom
    /// title in the file rather than one absent boolean.
    func test_anIndexFromAnOlderBuildStillDecodes() throws {
        let json = """
        [{"id":"chat-old","title":"Tuesday","titleIsCustom":true,\
        "createdAt":"2026-08-01T10:00:00Z","updatedAt":"2026-08-01T10:30:00Z",\
        "entryCount":12,"realtimeIDs":[]}]
        """
        let back = try ConversationArchive.decoder()
            .decode([SessionMeta].self, from: Data(json.utf8))
        XCTAssertEqual(back.first?.title, "Tuesday")
        XCTAssertEqual(back.first?.titleIsCustom, true)
        XCTAssertEqual(back.first?.pinned, false)
        XCTAssertNil(back.first?.pinnedAt)
    }

    func test_unpinningClearsTheDateSoNothingClaimsToStillBeLocked() {
        let catalog = SessionCatalog([meta("chat-a", minutesAgo: 3, pinned: true)])
        catalog.setPinned(false, for: "chat-a", now: t0)
        XCTAssertEqual(catalog.meta("chat-a")?.pinned, false)
        XCTAssertNil(catalog.meta("chat-a")?.pinnedAt)
        XCTAssertTrue(catalog.pinnedIDs.isEmpty)
    }

    func test_pinningSomethingThatIsNotInTheListDoesNotInventIt() {
        let catalog = SessionCatalog()
        XCTAssertNil(catalog.setPinned(true, for: "chat-ghost"),
                     "minting the row is the store's decision, not the catalogue's")
    }

    // MARK: - What opens on launch

    func test_aPinnedConversationIsWhatOpensEvenWhenItIsNotTheMostRecent() {
        let catalog = SessionCatalog([meta("recent", minutesAgo: 1),
                                      meta("locked", minutesAgo: 5_000, pinned: true)])
        XCTAssertEqual(catalog.sessionToResume?.id, "locked")
        XCTAssertEqual(catalog.mostRecentNonEmpty?.id, "recent")
    }

    func test_anEmptyPinnedConversationIsNotWorthReopening() {
        let catalog = SessionCatalog([meta("recent", minutesAgo: 1),
                                      meta("locked", minutesAgo: 5_000, pinned: true, entries: 0)])
        XCTAssertEqual(catalog.sessionToResume?.id, "recent",
                       "resuming into a blank conversation is a new one with extra steps")
    }
}
