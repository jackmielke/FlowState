import Foundation

/// The on-disk format of a conversation, in both directions.
///
/// One file per session, JSONL, one record per line:
///
///     {"kind":"entry","sessionID":"chat-…","speaker":"user","text":"…","at":"…Z",…}
///     {"kind":"summary","sessionID":"chat-…","text":"…",…}
///
/// The writing half already existed — this is the reading half, which is what turns a
/// privacy artefact ("you can go and look at what was kept") into a feature ("your
/// conversation is still here after a restart"). They live together so they cannot drift:
/// a format that can only be written is a format nobody notices has broken.
///
/// Reading is deliberately forgiving. A truncated last line — the app quit mid-write — or
/// a record from a future version with an unknown `kind` costs that line and nothing else.
/// The alternative, refusing the file, would throw away a whole conversation to protect
/// nobody from a missing sentence.
public enum ConversationArchive {

    /// Everything one session's file holds.
    public struct Archive: Equatable, Sendable {
        public var entries: [ConversationEntry]
        public var summaries: [ConversationSummary]
        /// Lines that could not be decoded. Surfaced rather than swallowed so a format
        /// that has genuinely broken is visible in Settings instead of silently halving
        /// everybody's history.
        public var skippedLines: Int
        /// How many corrections were folded in on the way. Reported so "the file has 40
        /// lines and the screen shows 38" has an answer that is not "a bug".
        public var editCount: Int

        public init(entries: [ConversationEntry] = [],
                    summaries: [ConversationSummary] = [],
                    skippedLines: Int = 0,
                    editCount: Int = 0) {
            self.entries = entries
            self.summaries = summaries
            self.skippedLines = skippedLines
            self.editCount = editCount
        }

        public var isEmpty: Bool { entries.isEmpty && summaries.isEmpty }
    }

    /// The record type tag, read before the record itself.
    private struct Kind: Decodable { var kind: String }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Writing

    public static func line(for entry: ConversationEntry) -> Data? {
        line(tag: "entry", encoding: entry)
    }

    public static func line(for summary: ConversationSummary) -> Data? {
        line(tag: "summary", encoding: summary)
    }

    /// A correction, appended after the line it corrects. Deletions get their own tag so
    /// a file can be read by eye and the two cannot be confused.
    public static func line(for edit: TranscriptEdit) -> Data? {
        line(tag: edit.isDeletion ? "delete" : "edit", encoding: edit)
    }

    /// Encodes one record with its `kind` alongside the fields themselves, rather than
    /// nested under a wrapper.
    ///
    /// Flat because that is what is already on disk in people's Application Support
    /// folders, and a format change that orphans the last month of somebody's
    /// conversations to save a few lines of encoding is not a trade worth making.
    private static func line<T: Encodable>(tag: String, encoding value: T) -> Data? {
        guard let data = try? encoder().encode(value),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        obj["kind"] = tag
        guard var line = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        else { return nil }
        line.append(0x0A)
        return line
    }

    // MARK: - Reading

    /// Parses a whole transcript file. Never throws — see the note above about
    /// forgiveness.
    public static func parse(_ data: Data) -> Archive {
        var out = Archive()
        var edits: [TranscriptEdit] = []
        let dec = decoder()

        for raw in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let line = Data(raw)
            // Blank and whitespace-only lines are not damage.
            guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) else { continue }

            guard let kind = try? dec.decode(Kind.self, from: line) else {
                out.skippedLines += 1
                continue
            }
            switch kind.kind {
            case "entry":
                if let e = try? dec.decode(ConversationEntry.self, from: line) {
                    out.entries.append(e)
                } else {
                    out.skippedLines += 1
                }
            case "summary":
                if let s = try? dec.decode(ConversationSummary.self, from: line) {
                    out.summaries.append(s)
                } else {
                    out.skippedLines += 1
                }
            case "edit", "delete":
                if let e = try? dec.decode(TranscriptEdit.self, from: line) {
                    edits.append(e)
                } else {
                    out.skippedLines += 1
                }
            default:
                // A record kind a later version writes. Not damage — just not ours.
                out.skippedLines += 1
            }
        }

        out.entries = apply(edits, to: out.entries)
        out.editCount = edits.count
        out.entries.sort { $0.at < $1.at }
        out.summaries.sort { $0.createdAt < $1.createdAt }
        return out
    }

    /// Folds corrections over the lines they correct.
    ///
    /// In file order, so a line edited twice ends up saying what it was last edited to,
    /// and an edit to a line that was later deleted loses to the deletion. An edit
    /// naming a line that is not in this file is dropped rather than resurrecting an
    /// entry from nothing — it means the transcript was trimmed underneath it.
    static func apply(_ edits: [TranscriptEdit], to entries: [ConversationEntry]) -> [ConversationEntry] {
        guard !edits.isEmpty else { return entries }
        var text: [UUID: String] = [:]
        var deleted = Set<UUID>()
        for edit in edits {
            if let t = edit.text {
                text[edit.entryID] = t
                deleted.remove(edit.entryID)
            } else {
                deleted.insert(edit.entryID)
                text[edit.entryID] = nil
            }
        }
        return entries.compactMap { entry in
            guard !deleted.contains(entry.id) else { return nil }
            guard let replacement = text[entry.id] else { return entry }
            var edited = entry
            edited.text = replacement
            return edited
        }
    }

    // MARK: - Rebuilding the index

    /// Everything the session list needs about a conversation, derived from the file
    /// alone.
    ///
    /// This is what makes the index disposable: delete `sessions.json` and the list
    /// rebuilds itself from the transcripts, minus only the titles a user typed
    /// themselves — which cannot be recovered because they were never in the transcript.
    public static func meta(for sessionID: String,
                            archive: Archive,
                            fallbackDate: Date,
                            now: Date = Date(),
                            calendar: Calendar = .current,
                            locale: Locale = .current) -> SessionMeta {
        let started = archive.entries.first?.at ?? fallbackDate
        let touched = max(archive.entries.last?.at ?? fallbackDate,
                          archive.summaries.last?.createdAt ?? fallbackDate)
        return SessionMeta(
            id: sessionID,
            title: SessionTitle.make(entries: archive.entries,
                                     summaries: archive.summaries,
                                     startedAt: started,
                                     now: now,
                                     calendar: calendar,
                                     locale: locale),
            titleIsCustom: false,
            createdAt: started,
            updatedAt: touched,
            entryCount: archive.entries.filter(\.isConversational).count,
            realtimeIDs: [])
    }
}
