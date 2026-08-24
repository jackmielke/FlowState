import Foundation

/// Who said it.
///
/// Mirrors the app's own `Speaker`, but lives here because the record is persisted and
/// tested, and neither of those may depend on AppKit.
public enum TranscriptSpeaker: String, Codable, Sendable, CaseIterable {
    case user, assistant, system
}

/// Where a line of text actually came from.
///
/// Worth recording per entry rather than assuming: the app has more than one way to
/// obtain the user's words, and a summary built from a placeholder should be
/// distinguishable after the fact from one built from a real transcription.
public enum TranscriptSource: String, Codable, Sendable {
    /// `conversation.item.input_audio_transcription.completed` off the realtime socket.
    /// The only user-speech source wired to a real service today.
    case realtimeAPI
    /// An on-device recogniser. See `LocalTranscriber` for the injection point.
    case onDevice
    /// Text the assistant streamed back (`response.output_audio_transcript.delta`).
    case assistantStream
    /// The app's own narration: tool results, task progress, summaries.
    case app
    /// A stand-in produced without any transcription service at all.
    case placeholder
}

/// What is kept about a spoken utterance: its shape, never its samples.
///
/// This is the "store user audio as metadata" half of the feature. Duration and level
/// are enough to answer the questions that actually get asked of a voice log — how long
/// did they talk, was the mic even picking anything up, did this line come from a real
/// utterance or from typed text — without keeping a recording of anybody's kitchen.
///
/// `clipPath` is the single exception, and it is only ever non-nil when the user has
/// explicitly turned on `TranscriptPrivacy.keepAudioClips`.
public struct UtteranceAudio: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var duration: TimeInterval
    public var sampleRate: Double
    public var channels: Int
    /// Bytes of PCM16 that went past the meter. Not stored — measured.
    public var byteCount: Int
    public var peakLevel: Float
    public var averageLevel: Float
    /// Set only when the user opted in to keeping audio on disk. Otherwise nil.
    public var clipPath: String?

    public init(startedAt: Date,
                duration: TimeInterval,
                sampleRate: Double,
                channels: Int = 1,
                byteCount: Int,
                peakLevel: Float,
                averageLevel: Float,
                clipPath: String? = nil) {
        self.startedAt = startedAt
        self.duration = duration
        self.sampleRate = sampleRate
        self.channels = channels
        self.byteCount = byteCount
        self.peakLevel = peakLevel
        self.averageLevel = averageLevel
        self.clipPath = clipPath
    }

    /// True when the utterance carried essentially no signal — a cough, a door, or a mic
    /// that is muted at the hardware level. Useful for explaining an empty transcript.
    public var isSilent: Bool { peakLevel < 0.01 }
}

/// One durable line of conversation.
///
/// Every entry carries the two things the rest of the feature needs to be able to ask
/// for: WHEN it was said, and WHICH session it belongs to. Both are required, not
/// optional — an entry that cannot be placed in a session is not worth keeping, because
/// nothing downstream (summaries, retention, "forget this conversation") can act on it.
public struct ConversationEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The realtime session id (`session.created`), or a locally minted id when the
    /// entry was produced with no socket open.
    public var sessionID: String
    public var speaker: TranscriptSpeaker
    public var text: String
    public var at: Date
    public var source: TranscriptSource
    public var audio: UtteranceAudio?
    /// True when `TranscriptPrivacy` rewrote the text on the way in. The original is
    /// never stored anywhere, so this flag is the only trace that it happened.
    public var redacted: Bool

    public init(id: UUID = UUID(),
                sessionID: String,
                speaker: TranscriptSpeaker,
                text: String,
                at: Date = Date(),
                source: TranscriptSource,
                audio: UtteranceAudio? = nil,
                redacted: Bool = false) {
        self.id = id
        self.sessionID = sessionID
        self.speaker = speaker
        self.text = text
        self.at = at
        self.source = source
        self.audio = audio
        self.redacted = redacted
    }

    /// True for the lines a summary is allowed to be built from. The app's own narration
    /// (tool results, task progress, previous summaries) is context, not conversation,
    /// and feeding it back in makes summaries that summarise themselves.
    public var isConversational: Bool { speaker == .user || speaker == .assistant }
}

/// A correction to a line that is already on disk.
///
/// Transcripts are append-only — that is what makes writing one safe while the app is
/// mid-sentence, and what makes a truncated last line cost one sentence instead of a
/// conversation. So an edit is not a rewrite of the file: it is another record, appended
/// after the line it corrects, and applied over the top when the file is read back.
/// `text == nil` is a deletion, which is the same mechanism saying "and this line is
/// gone" rather than a second, subtly different one.
///
/// The original text is not kept anywhere. An edit is the user changing what the record
/// says about them, and a "history" of that would defeat the point of offering it.
public struct TranscriptEdit: Codable, Equatable, Sendable {
    public var sessionID: String
    /// The `ConversationEntry.id` being corrected.
    public var entryID: UUID
    /// The new text, or nil to delete the line outright.
    public var text: String?
    /// When the correction was made — never the timestamp of the line itself, which must
    /// keep its place in the conversation.
    public var at: Date

    public init(sessionID: String, entryID: UUID, text: String?, at: Date = Date()) {
        self.sessionID = sessionID
        self.entryID = entryID
        self.text = text
        self.at = at
    }

    public var isDeletion: Bool { text == nil }
}

/// The in-memory record of a conversation, with the privacy policy applied at the door.
///
/// Deliberately a plain class with no actor, no I/O and no clock of its own: every rule
/// worth getting right here (what is admitted, what is redacted, what has expired, what
/// a summary may see) is decidable from its arguments, so all of it is testable.
/// Persistence lives one layer up in `ConversationStore`.
public final class ConversationLog {

    public private(set) var entries: [ConversationEntry] = []
    public private(set) var summaries: [ConversationSummary] = []

    /// Hard ceiling on entries held in memory. A long session must not grow without
    /// bound; the JSONL file on disk is the complete record when persistence is on.
    public let maxEntries: Int

    public var privacy: TranscriptPrivacy

    /// Conversations the user has pinned. Retention steps around them — see
    /// `purgeExpired`, which is the one place a line disappears without being asked to.
    public var pinnedSessions: Set<String> = []

    public init(privacy: TranscriptPrivacy = TranscriptPrivacy(), maxEntries: Int = 500) {
        self.privacy = privacy
        self.maxEntries = max(20, maxEntries)
    }

    // MARK: - Writing

    /// Applies the privacy policy and stores the line.
    ///
    /// Returns the entry as it was actually stored — redacted text and all — or nil when
    /// policy refused it. Callers should treat nil as "this was not recorded", never as
    /// an error: refusing to record is the feature working.
    @discardableResult
    public func append(sessionID: String,
                       speaker: TranscriptSpeaker,
                       text: String,
                       at: Date = Date(),
                       source: TranscriptSource,
                       audio: UtteranceAudio? = nil) -> ConversationEntry? {
        guard privacy.admits(speaker: speaker) else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let (clean, didRedact) = privacy.redact(trimmed)

        // Audio metadata is a separate opt-out from the text itself, and dropping the
        // clip path is not enough — the whole shape of the utterance goes.
        var keptAudio = privacy.captureAudioMetadata ? audio : nil
        if !privacy.keepAudioClips { keptAudio?.clipPath = nil }

        let entry = ConversationEntry(sessionID: sessionID,
                                      speaker: speaker,
                                      text: clean,
                                      at: at,
                                      source: source,
                                      audio: keptAudio,
                                      redacted: didRedact)
        entries.append(entry)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        return entry
    }

    /// Rewrites one line's text, in memory.
    ///
    /// Redaction runs again — the user may have typed the key back in — but the privacy
    /// gate does not: refusing an edit because recording is paused would leave the line
    /// on screen saying something the user has just corrected.
    ///
    /// - Returns: the entry as it now stands, or nil when there is no such line.
    @discardableResult
    public func edit(entryID: UUID, to text: String) -> ConversationEntry? {
        guard let i = entries.firstIndex(where: { $0.id == entryID }) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let (clean, didRedact) = privacy.redact(trimmed)
        entries[i].text = clean
        entries[i].redacted = entries[i].redacted || didRedact
        return entries[i]
    }

    /// Drops one line. The conversation around it is untouched.
    @discardableResult
    public func remove(entryID: UUID) -> ConversationEntry? {
        guard let i = entries.firstIndex(where: { $0.id == entryID }) else { return nil }
        return entries.remove(at: i)
    }

    public func append(summary: ConversationSummary) {
        summaries.append(summary)
        if summaries.count > 50 { summaries.removeFirst(summaries.count - 50) }
    }

    /// Puts a conversation read back off disk into memory.
    ///
    /// Deliberately not `append`: these lines were admitted, redacted and stored by the
    /// policy that was in force when they were said. Running them through the door a
    /// second time would re-redact already-redacted text, and — worse — would drop the
    /// user's entire history the moment they paused recording, because `append` refuses
    /// everything while paused. What privacy still governs on the way back in is
    /// retention, which is applied here: a transcript past its window does not come back
    /// to life because somebody clicked on it.
    ///
    /// Idempotent by entry id, so restoring a session that is already open is a no-op
    /// rather than a duplicate transcript.
    ///
    /// - Returns: how many entries were actually added.
    @discardableResult
    public func restore(entries incoming: [ConversationEntry],
                        summaries incomingSummaries: [ConversationSummary] = [],
                        now: Date = Date()) -> Int {
        let known = Set(entries.map(\.id))
        let fresh = incoming.filter {
            !known.contains($0.id)
                && (pinnedSessions.contains($0.sessionID) || !privacy.hasExpired($0.at, now: now))
        }
        if !fresh.isEmpty {
            entries.append(contentsOf: fresh)
            entries.sort { $0.at < $1.at }
            // Same ceiling as the live path, and the same casualty: the oldest lines.
            // The file on disk stays complete either way.
            if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        }

        let knownSummaries = Set(summaries.map(\.id))
        let freshSummaries = incomingSummaries.filter {
            !knownSummaries.contains($0.id)
                && (pinnedSessions.contains($0.sessionID)
                    || !privacy.hasExpired($0.createdAt, now: now))
        }
        if !freshSummaries.isEmpty {
            summaries.append(contentsOf: freshSummaries)
            summaries.sort { $0.createdAt < $1.createdAt }
            if summaries.count > 50 { summaries.removeFirst(summaries.count - 50) }
        }

        return fresh.count
    }

    // MARK: - Reading

    public func entries(inSession id: String) -> [ConversationEntry] {
        entries.filter { $0.sessionID == id }
    }

    /// Conversational lines after a cut-off, newest last. The input a summary is built
    /// from — see `SummaryJob`.
    public func conversation(inSession id: String, after cutoff: Date) -> [ConversationEntry] {
        entries.filter { $0.sessionID == id && $0.isConversational && $0.at > cutoff }
    }

    public func summaries(inSession id: String) -> [ConversationSummary] {
        summaries.filter { $0.sessionID == id }
    }

    /// Session ids present in the log, oldest first.
    public var sessionIDs: [String] {
        var seen = Set<String>()
        return entries.compactMap { seen.insert($0.sessionID).inserted ? $0.sessionID : nil }
    }

    // MARK: - Forgetting

    /// Drops everything older than the retention window. Returns how many entries went.
    ///
    /// Retention is enforced here rather than only at write time so that turning the
    /// window down actually deletes what is already held, instead of merely changing
    /// what happens next.
    ///
    /// Pinned conversations are exempt. That is not a hole in the privacy story — it is
    /// the user having said, per conversation, "keep this one", which is a preference
    /// like any other and is undone by unpinning or by Delete.
    @discardableResult
    public func purgeExpired(now: Date = Date()) -> Int {
        guard privacy.retentionHours > 0 else { return 0 }
        let before = entries.count
        entries.removeAll {
            !pinnedSessions.contains($0.sessionID) && privacy.hasExpired($0.at, now: now)
        }
        summaries.removeAll {
            !pinnedSessions.contains($0.sessionID) && privacy.hasExpired($0.createdAt, now: now)
        }
        return before - entries.count
    }

    @discardableResult
    public func forget(session id: String) -> Int {
        let before = entries.count
        entries.removeAll { $0.sessionID == id }
        summaries.removeAll { $0.sessionID == id }
        return before - entries.count
    }

    public func forgetEverything() {
        entries.removeAll()
        summaries.removeAll()
    }
}
