import Foundation

/// What is known about one saved conversation without opening it.
///
/// The transcript files are the truth — this is an index over them, and it is written so
/// that losing it costs nothing but a rescan. Every field here is either recoverable from
/// the JSONL (`createdAt`, `updatedAt`, `entryCount`) or is a user's own decision that
/// belongs nowhere else (`title` when `titleIsCustom`).
public struct SessionMeta: Codable, Equatable, Identifiable, Sendable {

    /// The local session id. Also the transcript's file name, so it must stay
    /// path-safe — see `SessionID.mint`.
    public var id: String
    public var title: String
    /// The user renamed this. Auto-titling never touches it again.
    public var titleIsCustom: Bool
    public var createdAt: Date
    /// Last time anything was recorded into it. What the list sorts by, because "most
    /// recently talked about" is what people mean by recent.
    public var updatedAt: Date
    /// Conversational lines only — the app's own narration is not conversation, and a
    /// session showing "84 lines" that were all connection notes would be a lie.
    public var entryCount: Int
    /// The realtime session ids (`session.created`) this conversation has run under.
    ///
    /// More than one is normal: a dropped socket, or a reconnect after lunch, continues
    /// the same conversation under a new API id. Keeping the list is what lets a
    /// transcript be lined up with anything the API reports later.
    public var realtimeIDs: [String]

    public init(id: String,
                title: String,
                titleIsCustom: Bool = false,
                createdAt: Date,
                updatedAt: Date,
                entryCount: Int = 0,
                realtimeIDs: [String] = []) {
        self.id = id
        self.title = title
        self.titleIsCustom = titleIsCustom
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.entryCount = entryCount
        self.realtimeIDs = realtimeIDs
    }

    /// Nothing was ever said in it. Such a session is not worth a file, a row in the
    /// list, or a line in the index — see `ConversationStore`, which refuses to write
    /// one until it has something to write.
    public var isEmpty: Bool { entryCount == 0 }
}

/// Minting the id a conversation is filed under.
public enum SessionID {

    /// A sortable, path-safe id: `chat-20260821-150412-9f3a`.
    ///
    /// Deliberately not the realtime API's session id. That one is minted by
    /// `session.created`, which means it does not exist until a socket opens, changes on
    /// every reconnect, and is gone entirely when the user is talking to a saved
    /// conversation with nothing connected. A conversation has to be able to own a file
    /// before any of that happens.
    ///
    /// The date prefix is not load-bearing — `createdAt` in the index is — but it makes a
    /// directory listing readable, which is the same reason the transcripts are JSONL.
    public static func mint(at date: Date = Date(),
                            calendar: Calendar = .current,
                            suffix: String? = nil) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let tail = suffix ?? String(UUID().uuidString.prefix(4)).lowercased()
        return "chat-" + f.string(from: date) + "-" + sanitize(tail)
    }

    /// Everything that reaches the filesystem goes through here. Session ids are also
    /// file names, and a file name is one `../` away from being a different file.
    public static func sanitize(_ raw: String) -> String {
        let safe = raw.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return safe.isEmpty ? "unknown" : String(safe.prefix(80))
    }
}

/// The list of conversations, and the rules for keeping it straight.
///
/// Pure bookkeeping: no disk, no clock of its own, every decision decidable from its
/// arguments — the same split the rest of this app uses. `ConversationStore` owns the
/// file the catalogue is written to and the moment it is written.
public final class SessionCatalog {

    private var byID: [String: SessionMeta] = [:]

    public init(_ sessions: [SessionMeta] = []) {
        for s in sessions { byID[s.id] = s }
    }

    public var all: [SessionMeta] { Array(byID.values) }

    /// Newest activity first. What the switcher shows, and the order "the last
    /// conversation" is resolved in.
    public var recents: [SessionMeta] {
        byID.values.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id > $1.id : $0.updatedAt > $1.updatedAt
        }
    }

    /// The session to reopen on launch when the user asked for that, or nil when there
    /// is nothing worth reopening. Empty sessions are skipped: resuming into a blank
    /// conversation is indistinguishable from starting a new one, minus the clarity.
    public var mostRecentNonEmpty: SessionMeta? { recents.first { !$0.isEmpty } }

    public func meta(_ id: String) -> SessionMeta? { byID[id] }

    public func contains(_ id: String) -> Bool { byID[id] != nil }

    @discardableResult
    public func upsert(_ meta: SessionMeta) -> SessionMeta {
        byID[meta.id] = meta
        return meta
    }

    @discardableResult
    public func remove(_ id: String) -> Bool { byID.removeValue(forKey: id) != nil }

    public func removeAll() { byID.removeAll() }

    /// Files a recorded line against its session, creating the session's row the first
    /// time one arrives.
    ///
    /// The title is regenerated here rather than at session creation because the first
    /// few lines are what a conversation is about, and they do not exist yet when it
    /// starts. `SessionTitle.shouldRegenerate` decides when to stop.
    @discardableResult
    public func record(sessionID: String,
                       at: Date,
                       conversational: Bool,
                       entries: [ConversationEntry] = [],
                       summaries: [ConversationSummary] = [],
                       now: Date = Date(),
                       calendar: Calendar = .current,
                       locale: Locale = .current) -> SessionMeta {
        var meta = byID[sessionID] ?? SessionMeta(
            id: sessionID,
            title: SessionTitle.timeLabel(for: at, now: now, calendar: calendar, locale: locale),
            createdAt: at,
            updatedAt: at)

        meta.updatedAt = max(meta.updatedAt, at)
        meta.createdAt = min(meta.createdAt, at)
        if conversational { meta.entryCount += 1 }

        if SessionTitle.shouldRegenerate(titleIsCustom: meta.titleIsCustom,
                                         entryCount: meta.entryCount) {
            meta.title = SessionTitle.make(entries: entries,
                                           summaries: summaries,
                                           startedAt: meta.createdAt,
                                           now: now,
                                           calendar: calendar,
                                           locale: locale)
        }

        byID[sessionID] = meta
        return meta
    }

    /// Notes which realtime session this conversation is currently running under.
    @discardableResult
    public func link(realtimeID: String, to sessionID: String) -> SessionMeta? {
        guard var meta = byID[sessionID] else { return nil }
        guard !meta.realtimeIDs.contains(realtimeID) else { return meta }
        meta.realtimeIDs.append(realtimeID)
        byID[sessionID] = meta
        return meta
    }

    /// Replaces an auto-generated title with a better auto-generated one.
    ///
    /// Distinct from `rename` on purpose: rename marks a title CUSTOM, which is right
    /// when a person types one and wrong for a machine-written one. A generated title
    /// must stay improvable by the next summary, and must never outrank a title the user
    /// chose — so this refuses outright when the title is custom.
    @discardableResult
    public func setGeneratedTitle(_ raw: String, for id: String) -> SessionMeta? {
        guard var meta = byID[id], !meta.titleIsCustom else { return nil }
        let trimmed = SessionTitle.collapseWhitespace(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        meta.title = trimmed
        meta.titleIsCustom = false
        byID[id] = meta
        return meta
    }

    /// The user's own name for a conversation. Empty or whitespace hands the title back
    /// to the generator rather than leaving a blank row.
    @discardableResult
    public func rename(_ id: String,
                       to raw: String,
                       entries: [ConversationEntry] = [],
                       summaries: [ConversationSummary] = [],
                       now: Date = Date(),
                       calendar: Calendar = .current,
                       locale: Locale = .current) -> SessionMeta? {
        guard var meta = byID[id] else { return nil }
        let trimmed = SessionTitle.collapseWhitespace(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            meta.titleIsCustom = false
            meta.title = SessionTitle.make(entries: entries,
                                           summaries: summaries,
                                           startedAt: meta.createdAt,
                                           now: now,
                                           calendar: calendar,
                                           locale: locale)
        } else {
            meta.titleIsCustom = true
            meta.title = String(trimmed.prefix(80))
        }
        byID[id] = meta
        return meta
    }

    // MARK: - Presentation

    /// Titles as they should be shown, with collisions broken by time.
    ///
    /// Two conversations about the same thing produce the same title, which is correct
    /// and also unusable — a menu with three rows called "The spacing on that button"
    /// picks the wrong one every time. Only the duplicates pay for the disambiguation.
    public static func displayTitles(_ metas: [SessionMeta],
                                     calendar: Calendar = .current,
                                     locale: Locale = .current) -> [String: String] {
        var counts: [String: Int] = [:]
        for m in metas { counts[m.title.lowercased(), default: 0] += 1 }

        let f = DateFormatter()
        f.calendar = calendar
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("d MMM HH:mm")

        var out: [String: String] = [:]
        for m in metas {
            out[m.id] = (counts[m.title.lowercased()] ?? 0) > 1
                ? m.title + " · " + f.string(from: m.createdAt)
                : m.title
        }
        return out
    }

    /// Recents cut into the buckets a person thinks in. Empty buckets are dropped, so a
    /// menu never shows a heading with nothing under it.
    public static func groupedByAge(_ metas: [SessionMeta],
                                    now: Date = Date(),
                                    calendar: Calendar = .current) -> [(title: String, sessions: [SessionMeta])] {
        var today: [SessionMeta] = []
        var yesterday: [SessionMeta] = []
        var week: [SessionMeta] = []
        var earlier: [SessionMeta] = []

        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)
        let startOfWeek = calendar.date(byAdding: .day, value: -7, to: startOfToday)

        for m in metas.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if m.updatedAt >= startOfToday {
                today.append(m)
            } else if let y = startOfYesterday, m.updatedAt >= y {
                yesterday.append(m)
            } else if let w = startOfWeek, m.updatedAt >= w {
                week.append(m)
            } else {
                earlier.append(m)
            }
        }

        return [("Today", today), ("Yesterday", yesterday),
                ("Previous 7 days", week), ("Earlier", earlier)]
            .filter { !$0.1.isEmpty }
            .map { (title: $0.0, sessions: $0.1) }
    }
}
