import XCTest
@testable import FlowStateCore

/// The list of conversations: what is in it, what it is called, and what it must never
/// silently lose.
final class SessionCatalogTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
    private let locale = Locale(identifier: "en_US_POSIX")

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

    /// Files the given entries one at a time, the way the store does.
    private func fill(_ catalog: SessionCatalog,
                      _ entries: [ConversationEntry],
                      session: String = "chat-a") {
        for (i, e) in entries.enumerated() {
            catalog.record(sessionID: session,
                           at: e.at,
                           conversational: e.isConversational,
                           entries: Array(entries.prefix(i + 1)),
                           now: t0.addingTimeInterval(1000),
                           calendar: calendar,
                           locale: locale)
        }
    }

    // MARK: - Identity

    func test_sessionIDsArePathSafeAndSortable() {
        let id = SessionID.mint(at: t0, calendar: calendar, suffix: "9f3a")
        XCTAssertEqual(id, "chat-20250812-120000-9f3a")
        XCTAssertFalse(id.contains("/"))

        // The whole point: a hostile id can never address a file outside the folder.
        XCTAssertEqual(SessionID.sanitize("../../etc/passwd"), "etcpasswd")
        XCTAssertEqual(SessionID.sanitize(""), "unknown")
        XCTAssertEqual(SessionID.sanitize("///"), "unknown")
    }

    // MARK: - Titles

    func test_aConversationIsNamedAfterWhatWasSaidInIt() {
        let catalog = SessionCatalog()
        fill(catalog, [entry("hey", offset: 0),
                       entry("can you fix the spacing on that button", offset: 5)])
        XCTAssertEqual(catalog.meta("chat-a")?.title, "Fix the spacing on that button")
    }

    func test_aTitleStartsOutAsWhenItHappened() {
        let catalog = SessionCatalog()
        catalog.record(sessionID: "chat-a", at: t0, conversational: false,
                       now: t0, calendar: calendar, locale: locale)
        XCTAssertEqual(catalog.meta("chat-a")?.title, "This afternoon")
        XCTAssertTrue(catalog.meta("chat-a")!.isEmpty, "narration is not conversation")
    }

    func test_renamingSticksAndIsNeverOverwritten() {
        let catalog = SessionCatalog()
        fill(catalog, [entry("fix the spacing on that button", offset: 0)])
        catalog.rename("chat-a", to: "  Button polish  ", now: t0, calendar: calendar, locale: locale)
        XCTAssertEqual(catalog.meta("chat-a")?.title, "Button polish")
        XCTAssertTrue(catalog.meta("chat-a")!.titleIsCustom)

        // More conversation must not take the name back off the user.
        fill(catalog, [entry("actually let's talk about the release script instead", offset: 30)])
        XCTAssertEqual(catalog.meta("chat-a")?.title, "Button polish")
    }

    func test_clearingANameHandsItBackToTheGenerator() {
        let catalog = SessionCatalog()
        let said = [entry("fix the spacing on that button", offset: 0)]
        fill(catalog, said)
        catalog.rename("chat-a", to: "Button polish", now: t0, calendar: calendar, locale: locale)
        catalog.rename("chat-a", to: "   ", entries: said, now: t0, calendar: calendar, locale: locale)
        XCTAssertFalse(catalog.meta("chat-a")!.titleIsCustom)
        XCTAssertEqual(catalog.meta("chat-a")?.title, "Fix the spacing on that button")
    }

    /// A title that keeps rewriting itself is a title nobody can find twice.
    func test_anAutoTitleStopsChangingOnceTheConversationHasSettled() {
        let catalog = SessionCatalog()
        var said: [ConversationEntry] = [entry("fix the spacing on that button", offset: 0)]
        for i in 1...(SessionTitle.settlesAfter + 4) {
            said.append(entry("and another completely different thing about deployment \(i)",
                              offset: TimeInterval(i)))
        }
        fill(catalog, said)
        XCTAssertEqual(catalog.meta("chat-a")?.title, "Fix the spacing on that button")
        XCTAssertEqual(catalog.meta("chat-a")?.entryCount, said.count)
    }

    func test_sameNamedConversationsAreToldApartByTime() {
        let a = SessionMeta(id: "a", title: "Fix the build", createdAt: t0, updatedAt: t0)
        let b = SessionMeta(id: "b", title: "Fix the build",
                            createdAt: t0.addingTimeInterval(86_400),
                            updatedAt: t0.addingTimeInterval(86_400))
        let c = SessionMeta(id: "c", title: "Release notes",
                            createdAt: t0, updatedAt: t0)

        let titles = SessionCatalog.displayTitles([a, b, c], calendar: calendar, locale: locale)
        XCTAssertEqual(titles["c"], "Release notes", "a unique title pays nothing")
        XCTAssertNotEqual(titles["a"], titles["b"])
        XCTAssertTrue(titles["a"]!.hasPrefix("Fix the build · "), titles["a"]!)
    }

    // MARK: - Bookkeeping

    func test_onlyConversationCountsAsConversation() {
        let catalog = SessionCatalog()
        catalog.record(sessionID: "chat-a", at: t0, conversational: false)
        catalog.record(sessionID: "chat-a", at: t0.addingTimeInterval(1), conversational: true)
        catalog.record(sessionID: "chat-a", at: t0.addingTimeInterval(2), conversational: true)
        XCTAssertEqual(catalog.meta("chat-a")?.entryCount, 2)
    }

    func test_theClockOnlyEverMovesTheRightWay() {
        let catalog = SessionCatalog()
        catalog.record(sessionID: "chat-a", at: t0.addingTimeInterval(500), conversational: true)
        // A late-arriving earlier line — a summary of an older window, a restored file —
        // must not make the conversation look older than its newest line.
        catalog.record(sessionID: "chat-a", at: t0, conversational: true)
        XCTAssertEqual(catalog.meta("chat-a")?.updatedAt, t0.addingTimeInterval(500))
        XCTAssertEqual(catalog.meta("chat-a")?.createdAt, t0)
    }

    /// A reconnect is the same conversation, not a new one — this is the list that says
    /// so afterwards.
    func test_everyRealtimeSessionIsRecordedAgainstTheConversation() {
        let catalog = SessionCatalog()
        catalog.record(sessionID: "chat-a", at: t0, conversational: true)
        catalog.link(realtimeID: "sess_1", to: "chat-a")
        catalog.link(realtimeID: "sess_2", to: "chat-a")
        catalog.link(realtimeID: "sess_1", to: "chat-a")   // idempotent
        XCTAssertEqual(catalog.meta("chat-a")?.realtimeIDs, ["sess_1", "sess_2"])
        XCTAssertNil(catalog.link(realtimeID: "sess_3", to: "nobody"))
    }

    func test_recentsAreOrderedByWhenTheyWereLastTouched() {
        let catalog = SessionCatalog()
        catalog.record(sessionID: "old", at: t0, conversational: true)
        catalog.record(sessionID: "new", at: t0.addingTimeInterval(600), conversational: true)
        catalog.record(sessionID: "middle", at: t0.addingTimeInterval(300), conversational: true)
        XCTAssertEqual(catalog.recents.map(\.id), ["new", "middle", "old"])
    }

    func test_resumingSkipsConversationsWhereNothingWasSaid() {
        let catalog = SessionCatalog()
        catalog.record(sessionID: "said-something", at: t0, conversational: true)
        catalog.record(sessionID: "empty", at: t0.addingTimeInterval(600), conversational: false)
        XCTAssertEqual(catalog.recents.first?.id, "empty")
        XCTAssertEqual(catalog.mostRecentNonEmpty?.id, "said-something")
    }

    func test_deletingRemovesItFromTheList() {
        let catalog = SessionCatalog()
        catalog.record(sessionID: "chat-a", at: t0, conversational: true)
        XCTAssertTrue(catalog.remove("chat-a"))
        XCTAssertFalse(catalog.remove("chat-a"))
        XCTAssertTrue(catalog.recents.isEmpty)
    }

    func test_groupingDropsEmptyBuckets() {
        let now = t0
        let today = SessionMeta(id: "t", title: "t", createdAt: now, updatedAt: now)
        let old = SessionMeta(id: "o", title: "o",
                              createdAt: now.addingTimeInterval(-40 * 86_400),
                              updatedAt: now.addingTimeInterval(-40 * 86_400))
        let groups = SessionCatalog.groupedByAge([today, old], now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["Today", "Earlier"])
        XCTAssertEqual(groups.first?.sessions.map(\.id), ["t"])
    }

    // MARK: - The index survives a restart

    func test_theIndexRoundTripsThroughJSON() throws {
        let meta = SessionMeta(id: "chat-a", title: "Button polish", titleIsCustom: true,
                               createdAt: t0, updatedAt: t0.addingTimeInterval(60),
                               entryCount: 9, realtimeIDs: ["sess_1"])
        let data = try ConversationArchive.encoder().encode([meta])
        let back = try ConversationArchive.decoder().decode([SessionMeta].self, from: data)
        XCTAssertEqual(back, [meta])
    }
}
