import Foundation
import FlowStateCore

/// Where a finished summary is delivered.
///
/// Split from the summariser because the two questions are genuinely independent: how a
/// summary gets written has nothing to do with where it ends up, and the useful
/// destinations (a note on disk, the live conversation, eventually Notion) arrive at
/// different times.
protocol NoteSink: Sendable {
    var name: String { get }
    /// Returns a short line describing what happened, for the system transcript.
    func write(_ summary: ConversationSummary) async -> String
}

/// A markdown note per day, appended to. Real, and works with nothing configured.
///
/// A file rather than a database for the same reason the transcript is JSONL: a summary
/// the user cannot open, read and delete is a summary they have to trust rather than
/// check.
struct MarkdownNoteSink: NoteSink {

    let name = "note"

    func write(_ summary: ConversationSummary) async -> String {
        let fm = FileManager.default
        let dir = ConversationStore.notesDirectory

        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"

        let url = dir.appendingPathComponent("\(day.string(from: summary.createdAt)).md")

        var block = "\n## \(clock.string(from: summary.createdAt)) · session \(summary.sessionID)\n\n"
        block += summary.text + "\n\n"
        block += "_\(summary.entryCount) turns, "
        block += "\(clock.string(from: summary.coveringFrom))–\(clock.string(from: summary.coveringTo)), "
        block += "written by \(summary.generator)._\n"

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(block.utf8))
            } else {
                let header = "# FlowState — \(day.string(from: summary.createdAt))\n"
                try Data((header + block).utf8).write(to: url, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            return "summary saved to \(url.lastPathComponent)"
        } catch {
            return "couldn't save the summary: \(error.localizedDescription)"
        }
    }
}

/// PLACEHOLDER — filing summaries into Notion.
///
/// Not implemented, and deliberately not guessed at. `Notion` in this app is read-only
/// today (search and read); appending a block needs a destination page the user has
/// chosen and shared with the integration, and there is nowhere to choose one yet. The
/// missing pieces, in order:
///
///  1. A `notionSummaryPageID` setting, populated by picking from `Notion.search`.
///  2. A write path in `Notion` — the token in `KeyStore` already has whatever access
///     the user granted it, so this is one request, not an auth project.
///  3. The same confirmation discipline the write-effect tools use (`ToolSpec.Effect`),
///     since this puts the user's conversation somewhere other people may be able to see.
///
/// Until then it says exactly what is missing rather than failing silently.
struct NotionNoteSink: NoteSink {
    let name = "notion"

    func write(_ summary: ConversationSummary) async -> String {
        guard Notion.isConfigured else {
            return "Notion isn't connected, so the summary stayed local."
        }
        return "Notion summaries aren't wired up yet — pick a destination page in "
             + "Settings first. The summary was saved locally."
    }
}

/// Runs the summarisation job: asks `SummaryJob` whether one is due, hands the digest to
/// a `Summarizer`, then files the result.
///
/// Nothing here decides WHEN — that is `SummaryJob`, in Core, where it is tested. This
/// is the part that owns the clock and the side effects.
@MainActor
final class SummaryService {

    private let store: ConversationStore
    private let job: SummaryJob
    private let summarizer: Summarizer
    private let sinks: [NoteSink]

    /// What happened to a finished summary, so `AppState` does not have to re-derive it
    /// from the policy it does not own.
    struct Delivery {
        /// The note sink's receipt, or nil when no note was written.
        var noteReceipt: String?
        /// Whether this summary should also be filed back into the live conversation, so
        /// the assistant can refer to it.
        var fileIntoChat: Bool
        /// A recap of a whole conversation, rather than one of the rolling summaries
        /// that keep the model's context small. Only this one is worth putting in front
        /// of the user — see `AppState.handleSummary`.
        var isFinal: Bool = false
    }

    /// Called on the main actor with every finished summary, so `AppState` can put it in
    /// the transcript and file it back into the conversation.
    var onSummary: ((ConversationSummary, Delivery) -> Void)?

    /// Called whenever a run starts or ends, including the ends that produce nothing.
    /// A button that says "Summarising…" needs to hear about the failure too, or it
    /// says it forever.
    var onActivity: (() -> Void)?

    /// True while a summariser is working. Read by the UI; owned by `SummaryJob`.
    var isSummarizing: Bool { job.isRunning }

    var policy: SummaryPolicy {
        get { job.policy }
        set { job.policy = newValue }
    }

    init(store: ConversationStore,
         policy: SummaryPolicy = SummaryPolicy(),
         // A real model by default now. It falls back to the extractive placeholder on
         // its own when there is no key or the call fails, so this stays offline-safe
         // while producing notes rather than quoted lines.
         summarizer: Summarizer = ModelSummarizer(grade: .rolling),
         // The one somebody reads. Written once per conversation, over the whole of it,
         // by the better model — see `ModelSummarizer.Grade`.
         finalSummarizer: Summarizer = ModelSummarizer(grade: .final),
         sinks: [NoteSink] = [MarkdownNoteSink()]) {
        self.store = store
        self.job = SummaryJob(policy: policy)
        self.summarizer = summarizer
        self.finalSummarizer = finalSummarizer
        self.sinks = sinks
    }

    private let finalSummarizer: Summarizer

    func begin(session id: String) { job.begin(session: id) }
    func end() { job.end() }

    /// The heartbeat. Cheap when nothing is due — which is almost always.
    ///
    /// - Parameter busy: true while the user is speaking or a turn is being generated.
    func tick(busy: Bool) {
        guard let digest = job.nextDigest(from: store.log, busy: busy) else { return }
        run(digest)
    }

    /// "Summarise what we've been talking about." Ignores the cadence, not the content:
    /// if there genuinely is not enough conversation yet, it says so rather than
    /// inventing a summary of two lines.
    @discardableResult
    func summarizeNow() -> String {
        guard let digest = job.nextDigest(from: store.log, busy: false, force: true) else {
            if job.isRunning { return "I'm already writing one — give me a second." }
            return "There isn't enough conversation yet to be worth summarising."
        }
        run(digest)
        return "Summarising the last \(digest.entries.count) turns now."
    }

    /// The Summary button: a recap of one whole session, live or finished.
    ///
    /// Takes the session id rather than assuming the live one, because the moment this
    /// is most wanted — "what did we just decide?" — is usually a moment after the
    /// socket has already gone.
    @discardableResult
    func summarizeSession(_ id: String) -> String {
        guard let digest = job.sessionDigest(id, from: store.log) else {
            if job.isRunning { return "I'm already writing one — give me a second." }
            return "There isn't enough of that conversation to summarise yet."
        }
        run(digest, using: finalSummarizer, final: true)
        return "Summarising \(digest.entries.count) turns."
    }

    private func run(_ digest: SummaryDigest,
                     using summarizer: Summarizer? = nil,
                     final: Bool = false) {
        let summarizer = summarizer ?? self.summarizer
        onActivity?()
        Task { @MainActor in
            guard let text = await summarizer.summarize(digest),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Nothing produced is not an error the user needs to hear about; the
                // next tick tries again over the same, still-uncovered window.
                job.abandon()
                onActivity?()
                return
            }

            let summary = job.complete(digest, text: text, generator: summarizer.name)
            store.record(summary)

            var receipt: String?
            if job.policy.destination.writesNote {
                for sink in sinks {
                    receipt = await sink.write(summary)
                }
            }
            onSummary?(summary, Delivery(noteReceipt: receipt,
                                         fileIntoChat: job.policy.destination.writesChat,
                                         isFinal: final))
            onActivity?()
        }
    }
}
