import Foundation
import os

/// Every moment in a transcript's life, on the console, in one format.
///
/// The transcript is the one part of this app whose bugs are invisible while they are
/// happening and unarguable afterwards: a conversation that came back short, a pin that
/// did not survive a relaunch, a file that was written and then trimmed. All of that is
/// decided across three layers — `ConversationLog` in Core, `ConversationStore` on disk,
/// `AppState` on screen — and none of them could previously be watched from outside.
///
/// So each of them reports here, and the report says the same three things every time:
/// what happened, to which conversation, and with what numbers attached.
///
///     [transcript] saved · chat-20260824-101500-a1b2 · 1 line, 412 bytes
///     [transcript] pinned · chat-20260824-101500-a1b2 · locked — retention will skip it
///     [transcript] restored · chat-20260824-101500-a1b2 · 34 lines, 2 edits folded in
///
/// Both to `os.Logger` — so `log stream --predicate 'category == "transcript"'` works on
/// a signed build with no terminal attached — and to stderr, so `swift run` shows it in
/// the window the developer is already looking at.
enum TranscriptLog {

    private static let logger = Logger(subsystem: "com.jackmielke.vibevoice",
                                       category: "transcript")

    /// The lifecycle worth watching. A closed set rather than free strings, so grepping
    /// for one of them finds every place it can happen.
    enum Event: String {
        case appended        // a line was recorded
        case edited          // a line's text was rewritten
        case removed         // a single line was deleted
        case saved           // a conversation was written to disk
        case loaded          // read back off disk
        case restored        // put on screen from what was read
        case cleared         // taken off screen without being deleted
        case deleted         // conversation and file gone
        case purged          // retention removed something
        case trimmed         // the keep-last limit removed something
        case pinned
        case unpinned
        case hidden          // the column was hidden — nothing was touched
        case shown
        case fault           // it did something it should not have been able to
    }

    static func event(_ event: Event, session: String? = nil, _ detail: String = "") {
        var line = "[transcript] \(event.rawValue)"
        if let session { line += " · \(session)" }
        if !detail.isEmpty { line += " · \(detail)" }

        switch event {
        case .fault:
            logger.error("\(line, privacy: .public)")
        default:
            logger.info("\(line, privacy: .public)")
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// "1 line" / "4 lines". Every count in these logs goes through it, because a log
    /// that says "1 lines" is a log somebody stops reading.
    static func lines(_ n: Int) -> String { "\(n) line\(n == 1 ? "" : "s")" }
}
