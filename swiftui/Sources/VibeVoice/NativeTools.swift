import Foundation
import AppKit
import EventKit
import VibeVoiceCore

/// Tools FlowState answers itself, in milliseconds, without spinning up Claude Code.
///
/// Everything here returns a short plain-language string, because the result is about to
/// be spoken. No JSON, no file paths, no code — if a tool wants to return a table, it is
/// the wrong shape for this app.
@MainActor
enum NativeTools {

    /// Control tools for Claude Code jobs. Separate from the list below because they are
    /// answered by AppState (which owns the registry) rather than by this type.
    static let taskControlSpecs: [ToolSpec] = [
        ToolSpec(
            name: "stop_task",
            summary: "Stop a task",
            description: "Stop a running Claude Code task, or drop a queued one that has not "
                       + "started, by its id (T1, T2…). Use the moment the user says stop, "
                       + "cancel, that's wrong, or 'don't bother with that one'. Edits already "
                       + "written by a running task stay on disk — offer to undo afterwards. A "
                       + "queued task has changed nothing, so there is nothing to undo.",
            parameters: [ToolParameter("task_id", description: "The task id, e.g. T1.", required: true)],
            effect: .writes(confirmation: "Stop it?")),

        ToolSpec(
            name: "undo_task",
            summary: "Undo a task",
            description: "Roll a repo back to how it was before a task started, by task id. "
                       + "Use when the user says undo, revert, or put it back. The task must "
                       + "have stopped or finished first.",
            parameters: [ToolParameter("task_id", description: "The task id, e.g. T1.", required: true)],
            effect: .writes(confirmation: "Want me to roll that back?")),

        ToolSpec(
            name: "set_queue_paused",
            summary: "Pause the task queue",
            description: "Pause or resume the Claude Code task queue. Pausing lets whatever "
                       + "is already running finish, then stops anything queued from starting "
                       + "by itself. Use when the user says pause the queue, hold off, stop "
                       + "starting new ones, or resume.",
            parameters: [ToolParameter("paused", type: "boolean",
                                       description: "true to pause, false to resume.", required: true)]),
    ]

    /// Conversation-memory tools. Also answered by AppState, for the same reason as the
    /// task controls: it owns the store, the summariser and the privacy settings.
    ///
    /// These are here rather than buried in Settings because the moment somebody wants
    /// recording to stop is a moment they are already talking — "don't write this down"
    /// has to work at the speed of a sentence, not of finding a checkbox.
    static let memorySpecs: [ToolSpec] = [
        ToolSpec(
            name: "summarize_conversation",
            summary: "Summarise this conversation",
            description: "Write a short summary of what has been said so far and save it "
                       + "as a note. Use when the user says summarise this, recap, or what "
                       + "did we decide. The summary arrives a moment later, so say you're "
                       + "writing it rather than inventing one."),

        ToolSpec(
            name: "go_to_sleep",
            summary: "Hang up",
            description: "Close the session and stop listening. Use whenever the user says "
                       + "go to sleep, that's all, we're done, goodbye, or you can go. "
                       + "Say a short goodbye first — the microphone closes a moment after "
                       + "you finish speaking, and going silent mid-sentence reads as a "
                       + "crash. Do not ask them to confirm."),

        ToolSpec(
            name: "memory_status",
            summary: "What's being kept",
            description: "What FlowState is currently recording about this conversation and "
                       + "for how long. Use whenever the user asks what you're keeping, "
                       + "whether you're recording, or where the transcript goes."),

        ToolSpec(
            name: "pause_recording",
            summary: "Stop recording",
            description: "Stop keeping any record of this conversation, immediately. Use "
                       + "the moment the user says don't record this, stop recording, or "
                       + "keep this off the record. Never ask them to confirm — do it, "
                       + "then say it's done."),

        ToolSpec(
            name: "resume_recording",
            summary: "Start recording again",
            description: "Start keeping a record of the conversation again after it was "
                       + "paused.",
            // Starting to keep somebody's words again is not a thing to do on a
            // misheard sentence.
            effect: .writes(confirmation: "Want me to start keeping a record again?")),

        ToolSpec(
            name: "forget_conversation",
            summary: "Forget this conversation",
            description: "Delete everything kept about this conversation — the transcript "
                       + "on screen and the file on disk. Use when the user says forget "
                       + "this, delete this, or wipe that.",
            effect: .writes(confirmation: "Delete everything from this conversation?")),
    ]

    static let specs: [ToolSpec] = [
        ToolSpec(
            name: "get_context",
            summary: "What I'm looking at",
            description: "What the user is doing on their Mac right now: the frontmost app "
                       + "and the time. Cheap — call it whenever context would help, and "
                       + "prefer it over asking for a screenshot when the app name is enough."),

        ToolSpec(
            name: "read_clipboard",
            summary: "Read the clipboard",
            description: "Read the text currently on the clipboard. Use when the user says "
                       + "things like \"what did I just copy\" or \"look at this\"."),

        ToolSpec(
            name: "get_calendar",
            summary: "Calendar",
            description: "The user's calendar events for today, or for a number of days ahead.",
            parameters: [ToolParameter("days_ahead", type: "number",
                                       description: "0 = today, 1 = today and tomorrow. Default 0.")]),

        ToolSpec(
            name: "list_shortcuts",
            summary: "List Shortcuts",
            description: "List the macOS Shortcuts available to run. Call this first if the "
                       + "user asks for something that sounds like one of their shortcuts."),

        ToolSpec(
            name: "run_shortcut",
            summary: "Run a Shortcut",
            description: "Run one of the user's macOS Shortcuts by name and return its output. "
                       + "Shortcuts are how this Mac reaches other apps, so prefer this over "
                       + "dispatching a coding task when a shortcut already does the job.",
            parameters: [
                ToolParameter("name", description: "Exact shortcut name from list_shortcuts.", required: true),
                ToolParameter("input", description: "Optional text input to pass in."),
            ],
            // A shortcut can do anything its author wrote, including send things.
            effect: .writes(confirmation: "Want me to run that shortcut?")),

        ToolSpec(
            name: "web_search",
            summary: "Search the web",
            description: "Look something up on the web and get a short spoken answer with "
                       + "current information. Use whenever the answer depends on anything "
                       + "recent, changing, or outside your training — prices, versions, "
                       + "news, releases, someone's current role, whether something shipped. "
                       + "Prefer this over guessing or saying you cannot know.",
            parameters: [ToolParameter("query", description: "What to look up, as a question.", required: true)]),

        ToolSpec(
            name: "notion_search",
            summary: "Search Notion",
            description: "Search the user's Notion for pages matching a query, newest first. "
                       + "Only pages shared with the integration are visible.",
            parameters: [ToolParameter("query", description: "What to look for.", required: true)]),

        ToolSpec(
            name: "notion_read",
            summary: "Read a Notion page",
            description: "Read the text of a Notion page. Pass the page title as the user said "
                       + "it — the title is looked up, so never ask them for an id.",
            parameters: [ToolParameter("page", description: "Page title, or a Notion page id.", required: true)]),
    ]

    static func run(_ name: String, args: [String: Any]) async -> String {
        switch name {
        case "get_context":     return context()
        case "read_clipboard":  return clipboard()
        case "get_calendar":    return await calendar(daysAhead: intArg(args["days_ahead"]) ?? 0)
        case "list_shortcuts":  return shortcutList()
        case "run_shortcut":    return await runShortcut(name: args["name"] as? String ?? "",
                                                         input: args["input"] as? String)
        case "web_search":      return await WebSearch.search(args["query"] as? String ?? "")
        case "notion_search":   return await Notion.search(args["query"] as? String ?? "")
        case "notion_read":     return await Notion.read(args["page"] as? String ?? "")
        default:                return "No such tool: \(name)."
        }
    }

    private static func intArg(_ v: Any?) -> Int? {
        (v as? Int) ?? (v as? Double).map(Int.init) ?? (v as? String).flatMap(Int.init)
    }

    // MARK: - Tools

    private static func context() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM, h:mm a"
        let when = f.string(from: Date())
        guard let app = NSWorkspace.shared.frontmostApplication?.localizedName else {
            return "It's \(when). I can't tell which app is in front."
        }
        return "It's \(when). The frontmost app is \(app)."
    }

    private static func clipboard() -> String {
        guard let s = NSPasteboard.general.string(forType: .string),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "The clipboard is empty, or holds something that isn't text."
        }
        // It is about to be read aloud, so cap it rather than reciting a whole file.
        return s.count > 1200
            ? "Clipboard (first part of \(s.count) characters): " + s.prefix(1200)
            : "Clipboard: " + s
    }

    private static func calendar(daysAhead: Int) async -> String {
        let store = EKEventStore()
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToEvents()
        } catch {
            return "Calendar access failed: \(error.localizedDescription)"
        }
        guard granted else {
            return "Calendar access is off. Turn it on in System Settings, Privacy & Security, "
                 + "Calendars, then ask again."
        }

        let cal = Foundation.Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: max(0, daysAhead) + 1, to: start) else {
            return "Couldn't work out that date range."
        }
        let events = store.events(matching: store.predicateForEvents(
            withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }

        guard !events.isEmpty else {
            return daysAhead == 0 ? "Nothing on the calendar today."
                                  : "Nothing on the calendar for the next \(daysAhead + 1) days."
        }
        let f = DateFormatter()
        f.dateFormat = daysAhead == 0 ? "h:mm a" : "EEE h:mm a"
        let lines = events.prefix(12).map { e -> String in
            let title = e.title ?? "Untitled"
            return e.isAllDay ? "all day: \(title)" : "\(f.string(from: e.startDate)) \(title)"
        }
        return lines.joined(separator: "; ")
    }

    private static func shortcutList() -> String {
        let out = shell("/usr/bin/shortcuts", ["list"])
        let names = out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return names.isEmpty ? "No shortcuts found."
                             : "Shortcuts: " + names.joined(separator: "; ")
    }

    private static func runShortcut(name: String, input: String?) async -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "No shortcut name given."
        }
        // `shortcuts run` reads and writes FILES, not stdin/stdout, so both ends are
        // temp files that get cleaned up afterwards.
        let dir = FileManager.default.temporaryDirectory
        let outURL = dir.appendingPathComponent("vv-shortcut-out-\(UUID().uuidString)")
        var args = ["run", name, "-o", outURL.path, "--output-type", "public.utf8-plain-text"]
        var inURL: URL?
        if let input, !input.isEmpty {
            let u = dir.appendingPathComponent("vv-shortcut-in-\(UUID().uuidString).txt")
            try? input.write(to: u, atomically: true, encoding: .utf8)
            inURL = u
            args += ["-i", u.path]
        }
        defer {
            try? FileManager.default.removeItem(at: outURL)
            if let inURL { try? FileManager.default.removeItem(at: inURL) }
        }

        let err = shell("/usr/bin/shortcuts", args, wantStderr: true)
        let produced = (try? String(contentsOf: outURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !produced.isEmpty {
            return produced.count > 1200 ? String(produced.prefix(1200)) : produced
        }
        if !err.isEmpty {
            return "The shortcut \"\(name)\" reported: \(err.prefix(300))"
        }
        return "Ran \"\(name)\". It finished without returning anything."
    }

    // MARK: -

    private static func shell(_ path: String, _ args: [String], wantStderr: Bool = false) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return "Could not run \(path): \(error.localizedDescription)" }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let stdout = String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if wantStderr && stdout.isEmpty {
            return String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return stdout
    }
}
