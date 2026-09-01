import Foundation
import Combine
import FlowStateCore

/// The durable side of a conversation: what was said, when, in which session, and what
/// the microphone looked like while it was being said.
///
/// `ConversationLog` in FlowStateCore owns the rules and is tested; this owns the clock,
/// the disk and the session lifecycle. The split is the same one the rest of this app
/// uses — anything decidable from its arguments lives in Core, anything that touches the
/// world lives here.
///
/// On disk it is JSONL, one entry per line, one file per session:
///
///     ~/Library/Application Support/FlowState/conversations/<sessionID>.jsonl
///     ~/Library/Application Support/FlowState/sessions.json      ← the index
///
/// JSONL rather than a database because the whole point of a privacy control is that the
/// user can go and look at what was kept, and delete it with `rm`. A file they can read
/// in Console.app is worth more here than an index they cannot.
///
/// The index is a convenience over those files and never the truth: deleting it costs
/// nothing but the titles the user typed by hand, because everything else in it can be
/// derived by reading the transcripts again. See `reloadCatalog()`.
///
/// ## Sessions
///
/// A session here is the app's own idea of a conversation, minted by `SessionID` and
/// owned for as long as the user is in it. That is deliberately *not* the realtime API's
/// `session.created` id, which cannot be the unit of a saved conversation: it does not
/// exist until a socket opens, it changes on every reconnect — so a dropped connection
/// used to shatter one conversation into several files — and it is absent entirely when
/// somebody is reading back a conversation with nothing connected. The API's ids are kept
/// alongside, in `SessionMeta.realtimeIDs`, so a transcript can still be lined up with
/// anything the API reports later.
@MainActor
final class ConversationStore: ObservableObject {

    let log: ConversationLog

    /// The conversation entries are being filed under. Always set: there is no state in
    /// which the user is not in *some* conversation, and making this optional only moved
    /// the question to every call site.
    @Published private(set) var currentSessionID: String
    /// When the current conversation began. Its fallback title, before anything is said.
    @Published private(set) var currentSessionStartedAt: Date
    /// Every saved conversation, most recently used first. What the switcher shows.
    @Published private(set) var sessions: [SessionMeta] = []
    /// Bumped on every write, so views can observe without holding the entries.
    @Published private(set) var entryCount = 0
    @Published private(set) var lastWriteError: String?
    /// Set when a transcript on disk could not be read back in full. Surfaced in
    /// Settings — a history that silently half-loads is worse than one that says so.
    @Published private(set) var lastReadError: String?

    /// The catalogue of conversations. Rules in Core, file here.
    private let catalog = SessionCatalog()
    /// Realtime session ids seen while the current conversation has been open. Applied to
    /// the catalogue as soon as it has a row to apply them to — which is the first time
    /// anything is actually recorded, since an empty conversation is not written down.
    private var currentRealtimeIDs: [String] = []

    /// How many conversations survive, and whether they are written without being asked.
    /// The hours half of the same question lives in `privacy.retentionHours`.
    var retention: TranscriptRetention {
        get { retentionPolicy }
        set {
            let was = retentionPolicy
            retentionPolicy = newValue
            guard was != newValue else { return }
            TranscriptLog.event(.policy, session: nil, newValue.summaryLine)
            // A limit that only applied to conversations recorded after it was set would
            // be a setting that appears to do nothing.
            trimToRetention()
        }
    }
    private var retentionPolicy = TranscriptRetention()

    var privacy: TranscriptPrivacy {
        get { log.privacy }
        set {
            let wasPersisting = log.privacy.persistToDisk
            log.privacy = newValue
            // Turning retention down has to bite immediately, not at the next launch.
            log.purgeExpired()
            // Turning persistence OFF is a request to stop keeping things, and leaving
            // yesterday's files sitting there would make it a lie. The list goes with
            // them: a switcher still offering conversations whose transcripts have just
            // been deleted is a menu of things that open empty.
            //
            // What is on screen right now is untouched. It is in memory, it was already
            // said, and hiding it would not un-say it.
            if wasPersisting && !newValue.persistToDisk {
                // Including pinned ones. A pin outranks retention, which is a policy
                // about age; it does not outrank "stop saving anything", which is the
                // user asking for nothing on disk at all. Said out loud in the log,
                // because it is the one place a lock loses.
                let lockedGoing = catalog.pinnedIDs.count
                deleteAllOnDisk()
                catalog.removeAll()
                publishSessions()
                TranscriptLog.event(.deleted, session: nil,
                                    "save-to-disk switched off — every transcript removed"
                                    + (lockedGoing > 0 ? ", including \(lockedGoing) pinned" : ""))
            }
        }
    }

    init(privacy: TranscriptPrivacy = TranscriptPrivacy(), now: Date = Date()) {
        self.log = ConversationLog(privacy: privacy)
        self.currentSessionID = SessionID.mint(at: now)
        self.currentSessionStartedAt = now
        log.purgeExpired()
        purgeExpiredFiles()
        reloadCatalog(now: now)
        syncPins()
    }

    // MARK: - Pinning

    /// Conversations the user has locked.
    var pinnedIDs: Set<String> { catalog.pinnedIDs }

    func isPinned(_ id: String) -> Bool { catalog.meta(id)?.pinned ?? false }

    var currentIsPinned: Bool { isPinned(currentSessionID) }

    /// Locks or unlocks a conversation.
    ///
    /// Pinning one that has never been written — the conversation you are in, before
    /// anybody has said anything worth keeping — mints its row here rather than waiting,
    /// because the pin IS the user saying it is worth keeping. The file follows as soon
    /// as there is a line to put in it, or immediately if there already is one.
    ///
    /// - Returns: whether it is now pinned.
    @discardableResult
    func setPinned(_ pinned: Bool, session id: String, now: Date = Date()) -> Bool {
        if catalog.meta(id) == nil {
            guard pinned else { return false }
            catalog.upsert(SessionMeta(id: id,
                                       title: SessionTitle.timeLabel(for: currentSessionStartedAt),
                                       createdAt: id == currentSessionID ? currentSessionStartedAt : now,
                                       updatedAt: now))
        }
        catalog.setPinned(pinned, for: id, now: now)
        syncPins()
        publishSessions()
        saveIndex()
        TranscriptLog.event(pinned ? .pinned : .unpinned, session: id,
                            pinned
                            ? "locked — retention, the keep-last limit and launch all honour it"
                            : "unlocked — retention applies to it again")
        // A pin in manual-save mode is also a promise that it will still be there
        // tomorrow, and that promise is only kept by a file.
        if pinned, privacy.persistToDisk, !log.entries(inSession: id).isEmpty {
            save(session: id)
        }
        if !pinned { trimToRetention() }
        return pinned
    }

    /// Hands the pin list down to the layer that enforces retention in memory.
    private func syncPins() { log.pinnedSessions = catalog.pinnedIDs }

    // MARK: - Session lifecycle

    /// Starts a fresh conversation. Nothing is written until something is said, so this
    /// costs no file and leaves no row in the list until it has earned one.
    ///
    /// The previous conversation is not closed in any meaningful sense — it is on disk,
    /// it is in the list, and reopening it picks up exactly where it stopped.
    @discardableResult
    func startNewSession(at: Date = Date()) -> String {
        let left = currentSessionID
        currentSessionID = SessionID.mint(at: at)
        currentSessionStartedAt = at
        currentRealtimeIDs = []
        TranscriptLog.event(.switched, session: currentSessionID,
                            "new conversation · \(left) left saved at "
                            + TranscriptLog.lines(log.entries(inSession: left).count))
        // A new conversation is one more conversation, which may put the collection over
        // the keep-last limit. The one just left is not a candidate: it is the newest.
        trimToRetention()
        return currentSessionID
    }

    /// Reopens a saved conversation and puts its history back in memory.
    ///
    /// - Returns: what was read, and — crucially — whether reading actually worked. A
    ///   conversation whose file could not be opened this instant is NOT an empty
    ///   conversation, and the caller must be able to tell the difference: one means
    ///   "there is nothing to show", the other means "do not touch what is on screen,
    ///   and try again". Before this returned a load rather than an archive, a transient
    ///   read error blanked the transcript and said "nothing was kept of it".
    @discardableResult
    func openSession(_ id: String, now: Date = Date()) -> ArchiveLoad {
        let load = loadArchive(for: id)
        guard let archive = load.archive else {
            // The session still becomes the current one — the user asked to be in it,
            // and refusing to move would strand them. What is on screen stays until a
            // retry succeeds.
            currentSessionID = id
            currentSessionStartedAt = catalog.meta(id)?.createdAt ?? now
            currentRealtimeIDs = []
            publishSessions()
            return load
        }
        log.restore(entries: archive.entries, summaries: archive.summaries, now: now)

        currentSessionID = id
        currentSessionStartedAt = archive.entries.first?.at
            ?? catalog.meta(id)?.createdAt
            ?? now
        currentRealtimeIDs = []

        // A conversation that was on disk but not in the index gets its row now, so
        // opening one from a rebuilt list does not leave it nameless.
        if catalog.meta(id) == nil, !archive.isEmpty {
            catalog.upsert(ConversationArchive.meta(for: id,
                                                    archive: archive,
                                                    fallbackDate: currentSessionStartedAt,
                                                    now: now))
        }
        entryCount = log.entries.count
        publishSessions()
        TranscriptLog.event(.restored, session: id,
                            "\(TranscriptLog.lines(archive.entries.count)) back in memory"
                            + (isPinned(id) ? " · pinned" : ""))
        return load
    }

    /// Notes the realtime session this conversation is currently running under.
    ///
    /// Called on every `session.created`, including reconnects, which is why the id is
    /// appended to a list rather than replacing one.
    func link(realtimeSession id: String) {
        guard !currentRealtimeIDs.contains(id) else { return }
        currentRealtimeIDs.append(id)
        if catalog.link(realtimeID: id, to: currentSessionID) != nil {
            publishSessions()
            saveIndex()
        }
        log.purgeExpired()
    }

    /// True while the title is still machine-written, i.e. safe to improve.
    func titleIsAuto(session id: String) -> Bool {
        guard let m = catalog.meta(id) else { return false }
        return !m.titleIsCustom
    }

    /// Everything recorded in one session, for naming it.
    func entries(inSession id: String) -> [ConversationEntry] { log.entries(inSession: id) }

    /// Installs a better generated title. No-op on a title the user set themselves.
    func setGeneratedTitle(_ title: String, session id: String) {
        guard catalog.setGeneratedTitle(title, for: id) != nil else { return }
        publishSessions()
        saveIndex()
    }

    /// The user's own name for a conversation. An empty string hands the title back to
    /// the generator rather than leaving a blank row in the list.
    func rename(session id: String, to title: String, now: Date = Date()) {
        guard catalog.rename(id,
                             to: title,
                             entries: log.entries(inSession: id),
                             summaries: log.summaries(inSession: id),
                             now: now) != nil else { return }
        publishSessions()
        saveIndex()
    }

    /// The title to put at the top of the sidebar right now.
    var currentTitle: String {
        catalog.meta(currentSessionID)?.title
            ?? SessionTitle.timeLabel(for: currentSessionStartedAt)
    }

    var currentMeta: SessionMeta? { catalog.meta(currentSessionID) }

    /// The conversation to reopen on launch when the user has asked for that. Empty
    /// conversations are skipped — resuming into a blank one is a new one with extra
    /// steps.
    var mostRecentSession: SessionMeta? { catalog.sessionToResume }

    /// Titles as the switcher should show them, with same-titled conversations
    /// disambiguated by when they happened.
    func displayTitles() -> [String: String] { SessionCatalog.displayTitles(sessions) }

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
        let sid = currentSessionID

        guard let entry = log.append(sessionID: sid,
                                     speaker: speaker,
                                     text: text,
                                     at: at,
                                     source: source,
                                     audio: audio) else { return nil }
        entryCount = log.entries.count
        appendToDisk(entry)
        noteInCatalog(sessionID: sid, at: entry.at, conversational: entry.isConversational)
        TranscriptLog.event(.appended, session: sid,
                            "\(entry.speaker.rawValue), \(entry.text.count) chars"
                            + (entry.redacted ? ", redacted" : "")
                            + (willPersist(session: sid) ? "" : ", memory only"))
        return entry
    }

    // MARK: - Editing

    /// Rewrites one line, in memory and on disk.
    ///
    /// The file is append-only, so the correction is appended as its own record rather
    /// than rewriting what is already there — see `TranscriptEdit`. That keeps a write
    /// during a live conversation as safe as it was, and it means a correction made
    /// while the disk is busy cannot cost the conversation around it.
    ///
    /// - Returns: the entry as it now stands, or nil when there is no such line.
    @discardableResult
    func edit(entryID: UUID, to text: String, at: Date = Date()) -> ConversationEntry? {
        guard let entry = log.edit(entryID: entryID, to: text) else {
            TranscriptLog.event(.fault, session: currentSessionID,
                                "edit for a line that is not in the log (\(entryID))")
            return nil
        }
        appendToDisk(TranscriptEdit(sessionID: entry.sessionID,
                                    entryID: entryID,
                                    text: entry.text,
                                    at: at))
        TranscriptLog.event(.edited, session: entry.sessionID,
                            "\(entry.text.count) chars"
                            + (willPersist(session: entry.sessionID) ? "" : ", memory only"))
        return entry
    }

    /// Deletes one line, in memory and on disk. Everything around it is untouched.
    @discardableResult
    func removeEntry(_ entryID: UUID, at: Date = Date()) -> Bool {
        guard let entry = log.remove(entryID: entryID) else { return false }
        entryCount = log.entries.count
        appendToDisk(TranscriptEdit(sessionID: entry.sessionID,
                                    entryID: entryID,
                                    text: nil,
                                    at: at))
        TranscriptLog.event(.removed, session: entry.sessionID,
                            "\(entry.speaker.rawValue) line deleted by hand")
        return true
    }

    // MARK: - Saving on purpose

    /// Writes a whole conversation to disk now, whatever the retention mode says.
    ///
    /// This is what "Only what I save" is for, and it is also the repair for a file that
    /// was never written because the disk was full at the wrong moment. It merges what
    /// is on disk with what is in memory and rewrites the file atomically, so calling it
    /// twice leaves one copy of everything rather than two.
    ///
    /// - Returns: how many lines the file holds afterwards, or nil when nothing could be
    ///   written — which callers must report rather than swallow.
    @discardableResult
    func save(session id: String, now: Date = Date()) -> Int? {
        guard privacy.persistToDisk else {
            TranscriptLog.event(.fault, session: id,
                                "asked to save with \"save to disk\" switched off — refused")
            return nil
        }
        let onDisk = loadArchive(for: id).archive ?? .init()

        var entries = onDisk.entries
        var seen = Set(entries.map(\.id))
        for e in log.entries(inSession: id) where !seen.contains(e.id) {
            entries.append(e)
            seen.insert(e.id)
        }
        entries.sort { $0.at < $1.at }

        var summaries = onDisk.summaries
        var seenSummaries = Set(summaries.map(\.id))
        for s in log.summaries(inSession: id) where !seenSummaries.contains(s.id) {
            summaries.append(s)
            seenSummaries.insert(s.id)
        }
        summaries.sort { $0.createdAt < $1.createdAt }

        guard !entries.isEmpty || !summaries.isEmpty else {
            TranscriptLog.event(.saved, session: id, "nothing to save yet")
            return 0
        }

        var blob = Data()
        for e in entries { if let line = ConversationArchive.line(for: e) { blob.append(line) } }
        for s in summaries { if let line = ConversationArchive.line(for: s) { blob.append(line) } }

        let url = transcriptURL(for: id)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try blob.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
            lastWriteError = nil
        } catch {
            lastWriteError = error.localizedDescription
            TranscriptLog.event(.fault, session: id, "save failed — \(error.localizedDescription)")
            return nil
        }

        // A conversation that was only in memory has no row until it is saved.
        if catalog.meta(id) == nil {
            catalog.upsert(ConversationArchive.meta(for: id,
                                                    archive: .init(entries: entries,
                                                                   summaries: summaries),
                                                    fallbackDate: currentSessionStartedAt,
                                                    now: now))
        }
        publishSessions()
        saveIndex()
        TranscriptLog.event(.saved, session: id,
                            "\(TranscriptLog.lines(entries.count)), \(blob.count) bytes → "
                            + url.lastPathComponent)
        return entries.count
    }

    /// Whether a line recorded into this conversation right now reaches the disk without
    /// anybody asking it to. False in `.manualSave` for anything unpinned — which is the
    /// mode working, not a failure, and is why it is said in the log next to the line.
    func willPersist(session id: String) -> Bool {
        privacy.persistToDisk && retentionPolicy.autosaves(pinned: isPinned(id))
    }

    func record(_ summary: ConversationSummary) {
        log.append(summary: summary)
        appendToDisk(summary)
        // A summary is not a turn, so it does not raise the count — but it is activity,
        // and it is exactly the context the title generator wants when the user has been
        // answering in single words.
        noteInCatalog(sessionID: summary.sessionID,
                      at: summary.createdAt,
                      conversational: false)
    }

    /// Keeps the index in step with what was just written: the count, the clock, and the
    /// title while it is still allowed to improve.
    private func noteInCatalog(sessionID sid: String, at: Date, conversational: Bool) {
        catalog.record(sessionID: sid,
                       at: at,
                       conversational: conversational,
                       entries: log.entries(inSession: sid),
                       summaries: log.summaries(inSession: sid))
        if sid == currentSessionID {
            for realtimeID in currentRealtimeIDs {
                catalog.link(realtimeID: realtimeID, to: sid)
            }
        }
        publishSessions()
        saveIndex()
    }

    // MARK: - Disk

    /// Where everything FlowState keeps lives. Settings, transcripts, notes, the index.
    ///
    /// `VIBEVOICE_HOME` moves the lot somewhere else for the length of one launch. That
    /// exists so this half of the app can be exercised for real — quit it, start it
    /// again, check the conversation came back — without a test run rummaging through
    /// somebody's actual conversations. Unset, which is every normal launch, it is
    /// Application Support as before.
    nonisolated static var root: URL {
        let env = ProcessInfo.processInfo.environment["VIBEVOICE_HOME"] ?? ""
        if !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlowState", isDirectory: true)
    }

    nonisolated static var conversationsDirectory: URL {
        root.appendingPathComponent("conversations", isDirectory: true)
    }

    nonisolated static var notesDirectory: URL {
        root.appendingPathComponent("notes", isDirectory: true)
    }

    /// The session index. Next to the transcripts rather than inside their folder, so
    /// "delete the conversations directory" cannot leave an index describing files that
    /// no longer exist.
    nonisolated static var sessionsIndexURL: URL {
        root.appendingPathComponent("sessions.json")
    }

    func transcriptURL(for sessionID: String) -> URL {
        // Session ids are minted by this app, but a path is a path — never build one from
        // a string that has not been reduced to something that cannot escape the folder.
        Self.conversationsDirectory
            .appendingPathComponent(SessionID.sanitize(sessionID))
            .appendingPathExtension("jsonl")
    }

    /// The three things reading a transcript can mean, kept apart on purpose.
    ///
    /// `missing` and `failed` used to be the same answer — an empty archive — and that
    /// single line was the whole bug behind "it opened the conversation and everything
    /// was gone". A file that is not there is a conversation with nothing in it. A file
    /// that would not open *this instant* is a conversation whose contents are still on
    /// the disk, and the only correct response is to leave the screen alone and read it
    /// again.
    enum ArchiveLoad {
        case loaded(ConversationArchive.Archive)
        /// No transcript file. A conversation that was never persisted, or was deleted.
        case missing
        /// The file exists and could not be read. Transient until proven otherwise.
        case failed(String)

        /// What was read, or nil when nothing could be.
        ///
        /// `missing` deliberately yields an empty archive rather than nil: there is
        /// genuinely nothing to show, and callers should render that.
        var archive: ConversationArchive.Archive? {
            switch self {
            case .loaded(let a): return a
            case .missing:       return .init()
            case .failed:        return nil
            }
        }

        var error: String? {
            if case .failed(let why) = self { return why }
            return nil
        }
    }

    /// Reads one conversation back off disk, saying which of the three things happened.
    func loadArchive(for sessionID: String) -> ArchiveLoad {
        let url = transcriptURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            let archive = ConversationArchive.parse(data)
            if archive.skippedLines > 0 {
                lastReadError = "\(archive.skippedLines) unreadable line(s) in \(url.lastPathComponent)"
            } else if lastReadError != nil {
                // A read that came back clean retires the last complaint, or Settings
                // keeps showing an error about a file that has since been fine.
                lastReadError = nil
            }
            TranscriptLog.event(.loaded, session: sessionID,
                                "\(TranscriptLog.lines(archive.entries.count)), "
                                + "\(archive.summaries.count) summar\(archive.summaries.count == 1 ? "y" : "ies")"
                                + (archive.editCount > 0 ? ", \(archive.editCount) correction(s) folded in" : "")
                                + (archive.skippedLines > 0 ? ", \(archive.skippedLines) unreadable" : "")
                                + ", \(data.count) bytes")
            return .loaded(archive)
        } catch {
            let why = "could not read \(url.lastPathComponent): \(error.localizedDescription)"
            lastReadError = why
            TranscriptLog.event(.fault, session: sessionID, why)
            return .failed(why)
        }
    }

    /// The retry-safe read. Same answer as `loadArchive`, but a file that is momentarily
    /// unreadable gets a few more chances before the user is told anything.
    ///
    /// Transcripts are appended to while they are being read, and `sessions.json` is
    /// replaced atomically underneath whoever is looking at it, so a single failed read
    /// says almost nothing. Backing off between attempts costs a few hundred
    /// milliseconds in the case that was going to fail anyway, and saves the far more
    /// common case from ever surfacing.
    func reloadArchive(for sessionID: String, attempts: Int = 3) async -> ArchiveLoad {
        var last: ArchiveLoad = .missing
        for attempt in 0..<max(1, attempts) {
            last = loadArchive(for: sessionID)
            switch last {
            case .loaded, .missing:
                return last
            case .failed:
                // 120 ms, 240 ms, 480 ms. Short enough to be invisible behind a refresh,
                // long enough to outlast a file being rewritten.
                let backoff = UInt64(120_000_000) << UInt64(attempt)
                try? await Task.sleep(nanoseconds: backoff)
            }
        }
        return last
    }

    /// Reads one conversation back off disk. Empty when there is no file *or* when the
    /// file would not open — kept for callers that genuinely cannot act on the
    /// difference. Anything that puts a transcript on screen must use `loadArchive`.
    func archive(for sessionID: String) -> ConversationArchive.Archive {
        loadArchive(for: sessionID).archive ?? .init()
    }

    private func appendToDisk(_ entry: ConversationEntry) {
        guard willPersist(session: entry.sessionID) else { return }
        guard let line = ConversationArchive.line(for: entry) else { return }
        write(line, to: transcriptURL(for: entry.sessionID))
    }

    private func appendToDisk(_ summary: ConversationSummary) {
        guard willPersist(session: summary.sessionID) else { return }
        guard let line = ConversationArchive.line(for: summary) else { return }
        write(line, to: transcriptURL(for: summary.sessionID))
    }

    /// A correction only needs writing when there is a file for it to correct. In
    /// manual-save mode there usually is not — the edit lives in memory and goes to disk
    /// with everything else when the user saves.
    private func appendToDisk(_ edit: TranscriptEdit) {
        guard privacy.persistToDisk else { return }
        let url = transcriptURL(for: edit.sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let line = ConversationArchive.line(for: edit) else { return }
        write(line, to: url)
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
            TranscriptLog.event(.fault, session: url.deletingPathExtension().lastPathComponent,
                                "write failed — \(error.localizedDescription)")
        }
    }

    // MARK: - The index

    /// Rebuilds the session list from the index and, where they disagree, from the
    /// transcripts themselves.
    ///
    /// The files win every disagreement. A row with no file is a conversation that has
    /// been deleted out from under us — by retention, by `rm`, by "delete everything" —
    /// and a file with no row is a conversation from a build before this one, or from an
    /// index that got lost. Both are recoverable, and neither should cost the user
    /// anything.
    /// Rebuilds the list from disk on demand.
    ///
    /// The same work `init` does, exposed because the files can change under a running
    /// app — retention deletes one, another window writes one, somebody drops a
    /// transcript into the folder by hand — and "quit and reopen it" is not an answer.
    /// Safe to call repeatedly: it is a rebuild, not a merge, so running it twice leaves
    /// the same list.
    func reloadCatalogFromDisk(now: Date = Date()) {
        purgeExpiredFiles()
        reloadCatalog(now: now)
    }

    private func reloadCatalog(now: Date = Date()) {
        catalog.removeAll()

        if privacy.persistToDisk,
           let data = try? Data(contentsOf: Self.sessionsIndexURL),
           let saved = try? ConversationArchive.decoder().decode([SessionMeta].self, from: data) {
            for meta in saved { catalog.upsert(meta) }
        }

        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: Self.conversationsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]))?
            .filter { $0.pathExtension == "jsonl" } ?? []

        var onDisk = Set<String>()
        // Newest first, so the cap below keeps what somebody might plausibly want back.
        let ordered = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }

        for url in ordered.prefix(Self.maxIndexedSessions) {
            let id = url.deletingPathExtension().lastPathComponent
            onDisk.insert(id)
            guard catalog.meta(id) == nil else { continue }
            // Only files the index does not already describe are parsed, so a normal
            // launch reads no transcripts at all.
            let parsed = ConversationArchive.parse((try? Data(contentsOf: url)) ?? Data())
            guard !parsed.isEmpty else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            catalog.upsert(ConversationArchive.meta(for: id,
                                                    archive: parsed,
                                                    fallbackDate: modified,
                                                    now: now))
        }

        // Rows whose transcript is gone. Only meaningful when transcripts are being
        // written at all — with persistence off there are no files to compare against,
        // and the whole list is this launch's memory.
        if privacy.persistToDisk {
            for meta in catalog.all where !onDisk.contains(meta.id) && meta.id != currentSessionID {
                // A pinned row with no file is not a stale row: in manual-save mode a
                // pin can be minted before anything has been written, and dropping it
                // here would forget a lock the moment the app restarted.
                if meta.pinned && meta.isEmpty { continue }
                catalog.remove(meta.id)
            }
        }

        publishSessions()
        saveIndex()
    }

    /// A ceiling on how many transcripts a cold launch will parse to rebuild a lost
    /// index. Well past what anybody scrolls to, and short of "read the whole disk".
    private static let maxIndexedSessions = 200

    private func publishSessions() {
        sessions = catalog.recents
    }

    private func saveIndex() {
        guard privacy.persistToDisk else { return }
        let enc = ConversationArchive.encoder()
        guard let data = try? enc.encode(catalog.recents) else { return }
        do {
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            try data.write(to: Self.sessionsIndexURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: Self.sessionsIndexURL.path)
        } catch {
            lastWriteError = error.localizedDescription
        }
    }

    // MARK: - Forgetting

    /// Deletes everything about one session, in memory and on disk.
    @discardableResult
    func forget(session id: String) -> Int {
        let dropped = log.forget(session: id)
        try? FileManager.default.removeItem(at: transcriptURL(for: id))
        catalog.remove(id)
        syncPins()
        TranscriptLog.event(.deleted, session: id,
                            dropped > 0
                            ? "\(TranscriptLog.lines(dropped)) and the file with them"
                            : "file removed — none of it was still in memory")
        entryCount = log.entries.count
        publishSessions()
        saveIndex()
        return dropped
    }

    /// The user-facing "forget all of this". Transcripts, summaries and any audio clips.
    func forgetEverything() {
        let had = sessions.count
        log.forgetEverything()
        entryCount = 0
        catalog.removeAll()
        syncPins()
        deleteAllOnDisk()
        publishSessions()
        TranscriptLog.event(.deleted, session: nil,
                            "delete everything — \(had) conversation\(had == 1 ? "" : "s") removed")
    }

    private func deleteAllOnDisk() {
        let fm = FileManager.default
        for dir in [Self.conversationsDirectory, AudioClipRecorder.directory] {
            try? fm.removeItem(at: dir)
        }
        // The index describes files that no longer exist, so it goes with them.
        try? fm.removeItem(at: Self.sessionsIndexURL)
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
        let pinned = catalog.pinnedIDs
        var removed = false
        for url in files {
            let id = url.deletingPathExtension().lastPathComponent
            // Pinned conversations do not age out. That is the whole of what a pin
            // promises, and it is undone by unpinning, by Delete, or by switching
            // saving off altogether.
            guard !pinned.contains(id) else { continue }
            guard id != currentSessionID else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, privacy.hasExpired(modified) {
                try? fm.removeItem(at: url)
                TranscriptLog.event(.purged, session: id,
                                    "older than \(TranscriptPrivacy.humanHours(privacy.retentionHours))")
                // The row goes with the file, or the switcher offers conversations that
                // open empty.
                if catalog.remove(id) { removed = true }
            }
        }
        if removed {
            publishSessions()
            saveIndex()
        }
    }

    /// Applies the keep-last limit: deletes the oldest conversations until the number
    /// on disk is back inside it.
    ///
    /// Never the pinned ones and never the one on screen — both exclusions live in
    /// `TranscriptRetention.sessionsToTrim`, where they can be tested without a disk.
    @discardableResult
    func trimToRetention() -> Int {
        guard privacy.persistToDisk else { return 0 }
        let doomed = retentionPolicy.sessionsToTrim(catalog.recents, current: currentSessionID)
        guard !doomed.isEmpty else { return 0 }
        for id in doomed {
            try? FileManager.default.removeItem(at: transcriptURL(for: id))
            log.forget(session: id)
            catalog.remove(id)
            TranscriptLog.event(.trimmed, session: id,
                                "past the keep-last-\(retentionPolicy.keepLast) limit")
        }
        entryCount = log.entries.count
        publishSessions()
        saveIndex()
        return doomed.count
    }

    // MARK: - Reading back

    /// The session a Summary button should act on. Always the current conversation now
    /// that one is always open — kept as an optional because callers still ask.
    var summarizableSessionID: String? { currentSessionID }

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
