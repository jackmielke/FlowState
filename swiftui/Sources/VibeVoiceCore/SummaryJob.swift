import Foundation

/// A concise account of a stretch of conversation, and what produced it.
public struct ConversationSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: String
    public var text: String
    /// The window this covers. Two summaries of one session tile rather than overlap:
    /// each starts where the last one stopped.
    public var coveringFrom: Date
    public var coveringTo: Date
    public var entryCount: Int
    public var createdAt: Date
    /// Which summariser wrote it — `ExtractiveSummarizer.name` today. Recorded because
    /// a placeholder summary and a model-written one should never be indistinguishable
    /// after the fact.
    public var generator: String

    public init(id: UUID = UUID(),
                sessionID: String,
                text: String,
                coveringFrom: Date,
                coveringTo: Date,
                entryCount: Int,
                createdAt: Date = Date(),
                generator: String) {
        self.id = id
        self.sessionID = sessionID
        self.text = text
        self.coveringFrom = coveringFrom
        self.coveringTo = coveringTo
        self.entryCount = entryCount
        self.createdAt = createdAt
        self.generator = generator
    }
}

/// Everything a summariser is given. Self-contained on purpose: whichever model ends up
/// doing the work — a local heuristic, an API call, Claude Code — gets the same input
/// and can be swapped without touching the scheduling.
public struct SummaryDigest: Equatable, Sendable {
    public var sessionID: String
    public var entries: [ConversationEntry]
    /// The last summary of this session, so a follow-up continues the story instead of
    /// restarting it.
    public var previousSummary: String?
    public var from: Date
    public var to: Date
    /// A ready-made prompt. Built here rather than at each call site so every summariser
    /// is answering the same question.
    public var prompt: String
}

/// The seam where a real summarisation model is injected.
///
/// `ExtractiveSummarizer` is the shipped default and needs no network, no key and no
/// subprocess, so the feature works out of the box. Anything better — a Responses API
/// call on the key already in `KeyStore`, a local model, Claude Code — conforms here and
/// is handed to `SummaryService` at construction. Nothing else changes.
public protocol Summarizer: Sendable {
    /// A short, stable name recorded on every summary this produces.
    var name: String { get }
    /// Returns nil when it could not produce anything. Nil is not an error the user
    /// should hear about — the job simply tries again on the next tick.
    func summarize(_ digest: SummaryDigest) async -> String?
}

/// When to summarise, and where the result goes.
public struct SummaryPolicy: Codable, Equatable, Sendable {

    public enum Destination: String, Codable, Sendable, CaseIterable {
        /// Filed back into the live conversation, so the assistant can refer to it.
        case chat
        /// Written as a markdown note on disk.
        case note
        case both

        public var writesChat: Bool { self == .chat || self == .both }
        public var writesNote: Bool { self == .note || self == .both }
    }

    public var enabled: Bool
    /// Summarise once this many new conversational lines have piled up.
    public var everyNEntries: Int
    /// …or once this long has passed with at least `minimumEntries` to say something
    /// about. Whichever comes first.
    public var everySeconds: TimeInterval
    /// Below this there is nothing worth summarising, and a one-line "summary" of one
    /// line is just that line again.
    public var minimumEntries: Int
    /// Ceiling on how much conversation goes into one summary.
    public var maxEntriesPerSummary: Int
    public var destination: Destination

    public init(enabled: Bool = true,
                everyNEntries: Int = 12,
                everySeconds: TimeInterval = 300,
                minimumEntries: Int = 4,
                maxEntriesPerSummary: Int = 40,
                destination: Destination = .both) {
        self.enabled = enabled
        self.everyNEntries = max(2, everyNEntries)
        self.everySeconds = max(30, everySeconds)
        self.minimumEntries = max(2, minimumEntries)
        self.maxEntriesPerSummary = max(4, maxEntriesPerSummary)
        self.destination = destination
    }
}

/// Decides WHEN a summary is due, and what goes into it. Does not generate anything.
///
/// Split out from `SummaryService` for the same reason `ResponseCoordinator` is split
/// out from `AppState`: the rules are the part that can be wrong in ways nobody notices
/// — summarising the same stretch twice, summarising over the user mid-sentence,
/// summarising two lines and calling it a summary — and all of them are decidable from
/// arguments, so all of them are tested.
public final class SummaryJob {

    public var policy: SummaryPolicy

    public private(set) var sessionID: String?
    /// The end of the last summarised window. The next summary starts strictly after it,
    /// which is what stops two summaries covering the same lines.
    public private(set) var coveredThrough: Date = .distantPast
    public private(set) var lastSummaryAt: Date = .distantPast
    /// True between `nextDigest` handing out work and `complete`/`abandon` coming back.
    /// A summariser can take seconds; without this the next tick starts a second one
    /// over the same lines.
    public private(set) var isRunning = false
    /// Backoff after a summariser produced nothing.
    ///
    /// Resetting the clock is not enough on its own: the cadence is count OR time, and a
    /// window that already met the count threshold meets it again on the very next tick,
    /// so a summariser that keeps failing gets hammered once per tick forever. This is
    /// the floor that stops it.
    public private(set) var retryNotBefore: Date = .distantPast

    public init(policy: SummaryPolicy = SummaryPolicy()) {
        self.policy = policy
    }

    /// Starts a new session. Everything about the previous one stops being relevant —
    /// including a run left in flight, which must not be allowed to complete into the
    /// new session's covered window.
    public func begin(session id: String, now: Date = Date()) {
        sessionID = id
        coveredThrough = .distantPast
        lastSummaryAt = now
        retryNotBefore = .distantPast
        isRunning = false
    }

    public func end() {
        sessionID = nil
        isRunning = false
    }

    /// The digest to summarise right now, or nil.
    ///
    /// - Parameter busy: true while the user is speaking or a spoken turn is being
    ///   generated. Summarising then is not wrong, but it competes for the same moment
    ///   the app should be listening, so it waits.
    /// - Parameter force: skip the cadence check (but not the "is there anything to say"
    ///   check). This is what "summarise what we just talked about" and end-of-session
    ///   use.
    public func nextDigest(from log: ConversationLog,
                           now: Date = Date(),
                           busy: Bool = false,
                           force: Bool = false) -> SummaryDigest? {
        guard let sessionID else { return nil }
        guard force || policy.enabled else { return nil }
        guard !isRunning else { return nil }
        guard force || !busy else { return nil }

        let fresh = log.conversation(inSession: sessionID, after: coveredThrough)
        guard fresh.count >= policy.minimumEntries else { return nil }

        if !force {
            guard now >= retryNotBefore else { return nil }
            let dueByCount = fresh.count >= policy.everyNEntries
            let dueByTime = now.timeIntervalSince(lastSummaryAt) >= policy.everySeconds
            guard dueByCount || dueByTime else { return nil }
        }

        let window = Array(fresh.suffix(policy.maxEntriesPerSummary))
        guard let first = window.first, let last = window.last else { return nil }

        let previous = log.summaries(inSession: sessionID).last?.text
        isRunning = true
        return SummaryDigest(sessionID: sessionID,
                             entries: window,
                             previousSummary: previous,
                             from: first.at,
                             to: last.at,
                             prompt: Self.prompt(for: window, previous: previous))
    }

    /// A recap of one whole session, asked for by name.
    ///
    /// Different from `nextDigest` in two ways that matter. It covers the session from
    /// the beginning rather than from `coveredThrough`, because somebody pressing a
    /// Summary button wants the conversation, not the last four minutes of it. And it
    /// takes the session id as an argument rather than reading `sessionID`, so it still
    /// works once the socket is gone and there is no live session at all — which is
    /// exactly when "what did we just decide?" gets asked.
    ///
    /// The cadence does not apply (this is a deliberate request), but the floor does:
    /// a "summary" of one line is that line again.
    public func sessionDigest(_ id: String,
                              from log: ConversationLog,
                              now: Date = Date()) -> SummaryDigest? {
        guard !isRunning else { return nil }
        let all = log.conversation(inSession: id, after: .distantPast)
        guard all.count >= Self.minimumForRecap else { return nil }

        let window = Array(all.suffix(policy.maxEntriesPerSummary))
        guard let first = window.first, let last = window.last else { return nil }

        isRunning = true
        // No previous summary: this is the whole story, not a continuation, and telling
        // the summariser "do not repeat this" would make it omit the beginning.
        return SummaryDigest(sessionID: id,
                             entries: window,
                             previousSummary: nil,
                             from: first.at,
                             to: last.at,
                             prompt: Self.prompt(for: window, previous: nil))
    }

    /// One exchange. Lower than `minimumEntries` on purpose — that floor stops the
    /// scheduler summarising thin air, while this one only has to stop a button
    /// summarising nothing at all.
    public static let minimumForRecap = 2

    /// Records a finished summary and advances the covered window.
    public func complete(_ digest: SummaryDigest, text: String, generator: String,
                         now: Date = Date()) -> ConversationSummary {
        isRunning = false
        // Only advance if this digest belongs to the session still open. A run that
        // straddles a reconnect would otherwise mark the NEW session's opening lines as
        // already covered.
        if digest.sessionID == sessionID {
            coveredThrough = max(coveredThrough, digest.to)
            lastSummaryAt = now
            retryNotBefore = .distantPast
        }
        return ConversationSummary(sessionID: digest.sessionID,
                                   text: text,
                                   coveringFrom: digest.from,
                                   coveringTo: digest.to,
                                   entryCount: digest.entries.count,
                                   createdAt: now,
                                   generator: generator)
    }

    /// The summariser produced nothing. The window stays uncovered so the same lines are
    /// tried again — but not immediately, and not on every tick.
    public func abandon(now: Date = Date()) {
        isRunning = false
        lastSummaryAt = now
        retryNotBefore = now.addingTimeInterval(min(policy.everySeconds, Self.retryBackoff))
    }

    /// Two minutes is long enough that a persistently failing summariser is not a load
    /// generator, and short enough that a transient failure is invisible.
    public static let retryBackoff: TimeInterval = 120

    // MARK: - Prompt

    /// The instruction handed to whichever model does the work.
    ///
    /// Written for speech: the result is going to be read aloud or dropped into a note,
    /// so it must not contain markdown, ids or file paths.
    public static func prompt(for entries: [ConversationEntry], previous: String?) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"

        var out = """
        Summarise this stretch of a spoken conversation between a user and their voice \
        assistant on a Mac.

        Rules:
        - Three sentences at most. Plain language, no markdown, no lists, no ids.
        - Concrete: names, decisions, numbers. Say what the user wanted and what was \
        actually decided or done.
        - Use nothing that is not written below. Do not guess at what was meant.
        - If something is unresolved, end with it in one clause.

        """

        if let previous, !previous.isEmpty {
            out += "\nEarlier in this conversation (for continuity, do not repeat it):\n"
            out += previous + "\n"
        }

        out += "\nConversation:\n"
        for e in entries {
            let who = e.speaker == .user ? "User" : "Assistant"
            out += "\(f.string(from: e.at)) \(who): \(e.text)\n"
        }
        return out
    }
}

/// The default summariser: no network, no key, no subprocess.
///
/// It is extractive rather than abstractive — it selects the load-bearing lines rather
/// than writing new prose — which means it can never hallucinate, and also means it
/// reads like notes rather than like a paragraph. That is the right trade for a
/// placeholder: it works offline on first launch, and it is obviously a placeholder, so
/// nobody ships it believing it is a language model.
///
/// Swap it for a real one by handing `SummaryService` a different `Summarizer`.
public struct ExtractiveSummarizer: Summarizer {

    public let name = "extractive-placeholder"

    public init() {}

    public func summarize(_ digest: SummaryDigest) async -> String? {
        let userLines = digest.entries.filter { $0.speaker == .user }.map(\.text)
        let assistantLines = digest.entries.filter { $0.speaker == .assistant }.map(\.text)
        guard !userLines.isEmpty || !assistantLines.isEmpty else { return nil }

        var parts: [String] = []

        // What the user actually pushed on: the longest distinct things they said,
        // in the order they said them.
        let asked = Self.salient(userLines, limit: 2)
        if !asked.isEmpty {
            parts.append("You asked about " + Self.joinNaturally(asked.map(Self.clause)) + ".")
        }

        // Where it ended up. The last full assistant sentence is a better ending than a
        // mid-stream fragment.
        if let closing = assistantLines.last.flatMap(Self.firstSentence), !closing.isEmpty {
            parts.append("I said: " + closing)
        }

        let minutes = max(1, Int(digest.to.timeIntervalSince(digest.from) / 60))
        parts.append("\(digest.entries.count) turns over about \(minutes) minute\(minutes == 1 ? "" : "s").")

        return parts.joined(separator: " ")
    }

    /// The longest lines, de-duplicated by their opening words, back in original order.
    /// Length is a crude proxy for substance, and a crude proxy is honest here.
    static func salient(_ lines: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var unique: [(index: Int, text: String)] = []
        for (i, line) in lines.enumerated() {
            let key = line.lowercased().split(separator: " ").prefix(4).joined(separator: " ")
            guard seen.insert(key).inserted else { continue }
            unique.append((i, line))
        }
        return unique
            .sorted { $0.text.count > $1.text.count }
            .prefix(limit)
            .sorted { $0.index < $1.index }
            .map(\.text)
    }

    /// Trims one line down to something that can sit inside a sentence.
    static func clause(_ s: String) -> String {
        var t = firstSentence(s) ?? s
        // Drop a trailing full stop so it does not collide with the sentence it joins.
        while let last = t.last, ".!?".contains(last) { t.removeLast() }
        let words = t.split(separator: " ")
        if words.count > 14 { t = words.prefix(14).joined(separator: " ") + "…" }
        return t.lowercased()
    }

    static func firstSentence(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let end = trimmed.firstIndex(where: { ".!?".contains($0) }) {
            let sentence = String(trimmed[...end])
            // A one-word "sentence" is an abbreviation, not an ending.
            if sentence.split(separator: " ").count > 2 { return sentence }
        }
        return trimmed.count > 180 ? String(trimmed.prefix(180)) + "…" : trimmed
    }

    static func joinNaturally(_ items: [String]) -> String {
        switch items.count {
        case 0:  return ""
        case 1:  return items[0]
        case 2:  return items[0] + ", and " + items[1]
        default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }
}
