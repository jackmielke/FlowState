import XCTest
@testable import VibeVoiceCore

/// A saved conversation is only findable if it is named after what happened in it. These
/// are the rules that stop a sidebar full of rows called "Hey".
final class SessionTitleTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private let locale = Locale(identifier: "en_US_POSIX")

    private func entry(_ text: String,
                       _ speaker: TranscriptSpeaker = .user,
                       at: TimeInterval) -> ConversationEntry {
        ConversationEntry(sessionID: "chat-test",
                          speaker: speaker,
                          text: text,
                          at: Date(timeIntervalSince1970: at),
                          source: speaker == .user ? .realtimeAPI : .assistantStream)
    }

    // MARK: - Topic

    func test_theTitleIsWhatTheUserActuallyAskedFor() {
        let title = SessionTitle.make(
            entries: [entry("hey vantage, could you tighten up the spacing on that button", at: 100)],
            startedAt: Date(timeIntervalSince1970: 100),
            now: Date(timeIntervalSince1970: 200),
            calendar: calendar, locale: locale)
        XCTAssertEqual(title, "Tighten up the spacing on that button")
    }

    /// The app has shipped under three names. A transcript recorded under any of them
    /// still has that name on the front of the first sentence, so all three are stripped
    /// — otherwise renaming the app would start naming conversations after it.
    func test_everyNameTheAppHasShippedUnderIsStrippedFromTheTitle() {
        for greeting in ["hey flowstate", "hey flow state", "hey flow",
                         "hey vantage", "hey vibe", "flowstate", "vantage"] {
            let title = SessionTitle.make(
                entries: [entry("\(greeting), could you tighten up the spacing on that button", at: 100)],
                startedAt: Date(timeIntervalSince1970: 100),
                now: Date(timeIntervalSince1970: 200),
                calendar: calendar, locale: locale)
            XCTAssertEqual(title, "Tighten up the spacing on that button",
                           "\(greeting) was not stripped")
        }
    }

    /// "flow" on its own is an ordinary English word, and stripping it would turn a real
    /// topic into a fragment. The bare name is only in the list as "flowstate".
    func test_theWordFlowOnItsOwnIsNotTreatedAsTheAppsName() {
        let title = SessionTitle.make(
            entries: [entry("flow charts render upside down", at: 100)],
            startedAt: Date(timeIntervalSince1970: 100),
            now: Date(timeIntervalSince1970: 200),
            calendar: calendar, locale: locale)
        XCTAssertEqual(title, "Flow charts render upside down")
    }

    /// The single most common opening in a voice app is a greeting, and naming every
    /// other conversation "Hey" is the failure mode this whole file exists to prevent.
    func test_greetingsAreSkippedForTheFirstRealRequest() {
        let title = SessionTitle.make(
            entries: [entry("hey", at: 100),
                      entry("you there?", at: 101),
                      entry("okay so what's on my calendar tomorrow", at: 110)],
            startedAt: Date(timeIntervalSince1970: 100),
            now: Date(timeIntervalSince1970: 200),
            calendar: calendar, locale: locale)
        XCTAssertEqual(title, "What's on my calendar tomorrow")
    }

    func test_openersAreStrippedOnlyOnWordBoundaries() {
        // "hi" must not eat the front of "history", "so" the front of "something".
        XCTAssertEqual(SessionTitle.stripOpeners("history of this repo"), "history of this repo")
        XCTAssertEqual(SessionTitle.stripOpeners("something is wrong with the mic"),
                       "something is wrong with the mic")
    }

    func test_strippingNeverEmptiesTheLine() {
        // Nothing left after the openers means the openers WERE the line.
        XCTAssertEqual(SessionTitle.stripOpeners("hey"), "hey")
        XCTAssertEqual(SessionTitle.stripOpeners("okay ok"), "okay ok")
    }

    func test_acknowledgementsAreNotTopics() {
        for said in ["yes", "ok", "sure", "mm", "no"] {
            XCTAssertNil(SessionTitle.condense(said), said)
        }
    }

    /// A conversation the user drove in single words still has to be called something,
    /// and the summary is the only thing that knows what it was about.
    func test_fallsBackToTheSummaryWhenTheUserSaidNothingSubstantial() {
        let summary = ConversationSummary(
            sessionID: "chat-test",
            text: "You asked about the release notes for the notarised build. I said: it's signed.",
            coveringFrom: Date(timeIntervalSince1970: 100),
            coveringTo: Date(timeIntervalSince1970: 400),
            entryCount: 6,
            createdAt: Date(timeIntervalSince1970: 400),
            generator: "test")

        let title = SessionTitle.make(
            entries: [entry("yes", at: 100), entry("do it", at: 120)],
            summaries: [summary],
            startedAt: Date(timeIntervalSince1970: 100),
            now: Date(timeIntervalSince1970: 500),
            calendar: calendar, locale: locale)
        XCTAssertEqual(title, "The release notes for the notarised build")
    }

    func test_aTitleIsNeverEmptyEvenWithNothingToGoOn() {
        let title = SessionTitle.make(entries: [],
                                      startedAt: Date(timeIntervalSince1970: 1_755_000_000),
                                      now: Date(timeIntervalSince1970: 1_755_000_000),
                                      calendar: calendar, locale: locale)
        XCTAssertFalse(title.isEmpty)
        XCTAssertEqual(title, SessionTitle.capitalizingFirst(
            "this " + SessionTitle.partOfDay(for: Date(timeIntervalSince1970: 1_755_000_000),
                                             calendar: calendar)))
    }

    // MARK: - Shape

    func test_titlesStayShortEnoughToRead() {
        let rambling = "can you please go through the whole audio engine and work out why "
                     + "the microphone keeps cutting out after about ninety seconds of talking"
        let title = SessionTitle.make(entries: [entry(rambling, at: 100)],
                                      startedAt: Date(timeIntervalSince1970: 100),
                                      now: Date(timeIntervalSince1970: 200),
                                      calendar: calendar, locale: locale)
        XCTAssertLessThanOrEqual(title.count, SessionTitle.maxCharacters + 1) // + the ellipsis
        XCTAssertLessThanOrEqual(title.split(separator: " ").count, SessionTitle.maxWords)
        XCTAssertTrue(title.hasSuffix("…"), "a cut title has to say it was cut: \(title)")
    }

    func test_titlesNeverContainNewlines() {
        let title = SessionTitle.make(
            entries: [entry("fix the\nbuild script\n\nplease", at: 100)],
            startedAt: Date(timeIntervalSince1970: 100),
            now: Date(timeIntervalSince1970: 200),
            calendar: calendar, locale: locale)
        XCTAssertFalse(title.contains("\n"))
        XCTAssertEqual(title, "Fix the build script")
    }

    /// A complete short sentence is not a truncation, so it keeps its last word.
    func test_aWholeSentenceIsNotTrimmedForEndingOnASmallWord() {
        XCTAssertEqual(SessionTitle.condense("what am I looking at"), "What am I looking at")
    }

    func test_aCutTitleDoesNotEndOnADanglingWord() {
        let title = SessionTitle.condense(
            "rewrite the release script and the notarisation step and the upload to")
        XCTAssertNotNil(title)
        XCTAssertFalse(title!.hasSuffix("and…"), title!)
        XCTAssertFalse(title!.hasSuffix("to…"), title!)
    }

    func test_onlyOneSentenceSurvives() {
        XCTAssertEqual(SessionTitle.condense("Check the build. Then push it to main."),
                       "Check the build")
    }

    // MARK: - Time

    func test_timeLabelsReadTheWaySomebodyWouldSayThem() {
        let now = Date(timeIntervalSince1970: 1_755_000_000)   // 2025-08-12 12:00:00 UTC
        XCTAssertEqual(SessionTitle.timeLabel(for: now, now: now, calendar: calendar, locale: locale),
                       "This afternoon")

        let yesterdayMorning = now.addingTimeInterval(-24 * 3600 - 4 * 3600)
        XCTAssertEqual(SessionTitle.timeLabel(for: yesterdayMorning, now: now,
                                              calendar: calendar, locale: locale),
                       "Yesterday morning")

        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 3600)
        let weekday = SessionTitle.timeLabel(for: threeDaysAgo, now: now,
                                             calendar: calendar, locale: locale)
        XCTAssertTrue(weekday.hasSuffix("afternoon"), weekday)
        XCTAssertFalse(weekday.hasPrefix("This"), weekday)

        let longAgo = now.addingTimeInterval(-40 * 24 * 3600)
        let old = SessionTitle.timeLabel(for: longAgo, now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(old.contains("Jul"), old)
    }

    func test_partOfDayUsesTheBoundariesPeopleActuallyUse() {
        func label(hour: Int) -> String {
            var c = DateComponents()
            c.year = 2026; c.month = 8; c.day = 21; c.hour = hour
            return SessionTitle.partOfDay(for: calendar.date(from: c)!, calendar: calendar)
        }
        XCTAssertEqual(label(hour: 2), "night")
        XCTAssertEqual(label(hour: 8), "morning")
        XCTAssertEqual(label(hour: 14), "afternoon")
        XCTAssertEqual(label(hour: 19), "evening")
        XCTAssertEqual(label(hour: 23), "night")
    }

    // MARK: - When a title is allowed to change

    func test_aUserTitleIsNeverRegenerated() {
        XCTAssertFalse(SessionTitle.shouldRegenerate(titleIsCustom: true, entryCount: 0))
        XCTAssertFalse(SessionTitle.shouldRegenerate(titleIsCustom: true, entryCount: 3))
    }

    func test_anAutoTitleImprovesEarlyAndThenSettles() {
        XCTAssertTrue(SessionTitle.shouldRegenerate(titleIsCustom: false, entryCount: 1))
        XCTAssertTrue(SessionTitle.shouldRegenerate(titleIsCustom: false,
                                                    entryCount: SessionTitle.settlesAfter))
        XCTAssertFalse(SessionTitle.shouldRegenerate(titleIsCustom: false,
                                                     entryCount: SessionTitle.settlesAfter + 1))
    }
}
