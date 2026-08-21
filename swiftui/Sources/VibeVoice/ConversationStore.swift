import Foundation
import Combine
import VibeVoiceCore

/// The durable side of a conversation: what was said, when, in which session, and what
/// the microphone looked like while it was being said.
///
/// `ConversationLog` in VibeVoiceCore owns the rules and is tested; this owns the clock,
/// the disk and the session lifecycle. The split is the same one the rest of this app
/// uses — anything decidable from its arguments lives in Core, anything that touches the
/// world lives here.
///
/// On disk it is JSONL, one entry per line, one file per session:
///
///     ~/Library/Application Support/VibeVoice/conversations/<sessionID>.jsonl
///
/// JSONL rather than a database because the whole point of a privacy control is that the
/// user can go and look at what was kept, and delete it with `rm`. A file they can read
/// in Console.app is worth more here than an index they cannot.
@MainActor
final class ConversationStore: ObservableObject {

    let log: ConversationLog

    /// The session entries are being filed under. Set from `session.created`, so it is
    /// the same id the API knows the conversation by.
    @Published private(set) var currentSessionID: String?
    /// Bumped on every write, so views can observe without holding the entries.
    @Published private(set) var entryCount = 0
    @Published private(set) var lastWriteError: String?

    var privacy: TranscriptPrivacy {
        get { log.privacy }
        set {
            let wasPersisting = log.privacy.persistToDisk
            log.privacy = newValue
            // Turning retention down has to bite immediately, not at the next launch.
            log.purgeExpired()
            // Turning persistence OFF is a request to stop keeping things, and leaving
            // yesterday's files sitting there would make it a lie.
            if wasPersisting && !newValue.persistToDisk { deleteAllOnDisk() }
        }
    }

    init(privacy: TranscriptPrivacy = TranscriptPrivacy()) {
        self.log = ConversationLog(privacy: privacy)
        log.purgeExpired()
        purgeExpiredFiles()
    }

    // MARK: - Session lifecycle

    /// Begins recording under the realtime session's own id.
    func beginSession(id: String) {
        currentSessionID = id
        log.purgeExpired()
    }

    /// A session id for entries produced with no socket open — a note filed before
    /// connecting, a summary asked for after disconnecting. Prefixed so it is obvious in
    /// a directory listing which files came from a real conversation.
    func beginLocalSession() {
        currentSessionID = "local-" + UUID().uuidString.prefix(8).lowercased()
    }

    func endSession() {
        currentSessionID = nil
    }

    // MARK: - Writing

    /// Records one line. Returns what was actually stored, or nil if privacy refused it.
    ///
    /// Callers must not treat nil as a failure — see `ConversationLog.append`. The live
    /// on-screen transcript is appended separately and unconditionally, because it shows
    /// what was said rather than what was kept.
    @discardableResult
    func record(speaker: TranscriptSpeaker,
                text: String,
                source: TranscriptSource,
                audio: UtteranceAudio? = nil,
                at: Date = Date()) -> ConversationEntry? {
        let sid = currentSessionID ?? {
            beginLocalSession()
            return currentSessionID!
        }()

        guard let entry = log.append(sessionID: sid,
                                     speaker: speaker,
                                     text: text,
                                     at: at,
                                     source: source,
                                     audio: audio) else { return nil }
        entryCount = log.entries.count
        appendToDisk(entry)
        return entry
    }

    func record(_ summary: ConversationSummary) {
        log.append(summary: summary)
        appendToDisk(summary)
    }

    // MARK: - Disk

    nonisolated static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeVoice", isDirectory: true)
    }

    nonisolated static var conversationsDirectory: URL {
        root.appendingPathComponent("conversations", isDirectory: true)
    }

    nonisolated static var notesDirectory: URL {
        root.appendingPathComponent("notes", isDirectory: true)
    }

    func transcriptURL(for sessionID: String) -> URL {
        // Session ids come from the API, but a path is a path — never build one from a
        // string that has not been reduced to something that cannot escape the folder.
        let safe = sessionID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return Self.conversationsDirectory
            .appendingPathComponent(safe.isEmpty ? "unknown" : safe)
            .appendingPathExtension("jsonl")
    }

    private func appendToDisk(_ entry: ConversationEntry) {
        guard privacy.persistToDisk else { return }
        guard let line = Self.jsonLine(["kind": "entry"], encoding: entry) else { return }
        write(line, to: transcriptURL(for: entry.sessionID))
    }

    private func appendToDisk(_ summary: ConversationSummary) {
        guard privacy.persistToDisk else { return }
        guard let line = Self.jsonLine(["kind": "summary"], encoding: summary) else { return }
        write(line, to: transcriptURL(for: summary.sessionID))
    }

    /// Encodes one record with a `kind` tag, so a reader can tell entries from summaries
    /// without guessing from which keys are present.
    private static func jsonLine<T: Encodable>(_ tags: [String: String], encoding value: T) -> Data? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(value),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        for (k, v) in tags { obj[k] = v }
        guard var line = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        else { return nil }
        line.append(0x0A)
        return line
    }

    private func write(_ line: Data, to url: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
                // A conversation is as private as the API key next to it.
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            if lastWriteError != nil { lastWriteError = nil }
        } catch {
            // Never fatal, and never a banner: failing to persist must not interrupt a
            // live conversation. It is surfaced in Settings instead.
            lastWriteError = error.localizedDescription
            FileHandle.standardError.write(Data("[conversation] write failed: \(error)\n".utf8))
        }
    }

    // MARK: - Forgetting

    /// Deletes everything about one session, in memory and on disk.
    @discardableResult
    func forget(session id: String) -> Int {
        let dropped = log.forget(session: id)
        try? FileManager.default.removeItem(at: transcriptURL(for: id))
        entryCount = log.entries.count
        return dropped
    }

    /// The user-facing "forget all of this". Transcripts, summaries and any audio clips.
    func forgetEverything() {
        log.forgetEverything()
        entryCount = 0
        deleteAllOnDisk()
    }

    private func deleteAllOnDisk() {
        let fm = FileManager.default
        for dir in [Self.conversationsDirectory, AudioClipRecorder.directory] {
            try? fm.removeItem(at: dir)
        }
    }

    /// Applies the retention window to files, not just to memory. Runs on launch and
    /// whenever the window changes — otherwise a transcript from three weeks ago would
    /// outlive a setting that says a week.
    func purgeExpiredFiles() {
        guard privacy.retentionHours > 0 else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.conversationsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in files {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, privacy.hasExpired(modified) {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Reading back

    /// The session a Summary button should act on: the live one, or the last one on
    /// record. A conversation does not stop being worth summarising the moment the
    /// socket closes — that is usually when somebody wants the recap.
    var summarizableSessionID: String? { currentSessionID ?? log.sessionIDs.last }

    /// How many of a session's lines a summary could actually be built from — user and
    /// assistant speech, never the app's own narration.
    func conversationalCount(inSession id: String) -> Int {
        log.conversation(inSession: id, after: .distantPast).count
    }

    /// Everything written about a session, newest first, for the summary panel.
    func summaries(inSession id: String) -> [ConversationSummary] {
        log.summaries(inSession: id).sorted { $0.createdAt > $1.createdAt }
    }

    /// Every summary held this launch, newest first — including sessions that have
    /// since ended, so yesterday's recap does not vanish on reconnect.
    var allSummaries: [ConversationSummary] {
        log.summaries.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Reporting

    /// Bytes currently held on disk. Shown in Settings, because "we keep a transcript" is
    /// an abstraction until there is a number next to it.
    var bytesOnDisk: Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.conversationsDirectory,
                                                      includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        return files.reduce(0) {
            $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    /// One speakable line about the state of the record. The assistant can be asked this
    /// out loud ("what are you keeping?"), so it is written to be heard.
    var spokenStatus: String {
        if privacy.paused { return "Recording is paused. Nothing from this conversation is being kept." }
        let kept = log.entries.count
        guard kept > 0 else { return "Nothing recorded yet this session. " + privacy.summaryLine }
        return "\(kept) line\(kept == 1 ? "" : "s") kept. " + privacy.summaryLine
    }
}
