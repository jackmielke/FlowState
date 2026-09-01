import Foundation

/// The fast lane: one model call that rewrites one file.
///
/// `dispatch_to_claude_code` runs a whole agent — it reads the repo, plans, edits,
/// verifies, and takes minutes. That is the right shape for "add dictation", and absurd
/// for "make ⌃Q a toggle". Measured on this machine, the same one-line change:
///
///     agent loop, via the CLI      12.5s   (of which ~6s is the CLI starting up)
///     one call, no tools            7.6s
///     the model's actual work      ~1.5s
///
/// So this skips the loop AND the subprocess: the file goes up, the whole file comes
/// back, it is written. No planning, no tool calls, no second opinion.
///
/// What pays for that speed is scope. This is for changes somebody could describe in one
/// sentence and point at one file for. Everything else belongs in the agent, and the
/// model is told so — a fast lane that quietly attempts hard things is worse than no
/// fast lane, because the failures arrive looking like successes.
public enum QuickEdit {

    /// Files past this are not quick-edit material: the whole thing is sent and returned,
    /// so a large file costs latency at both ends and invites a truncated rewrite.
    public static let maxBytes = 60_000

    public enum Refusal: Equatable {
        case tooLarge(bytes: Int)
        case empty
        /// The reply came back so much shorter than the file that it is far more likely
        /// to be a truncated generation than an edit. Overwriting good code with half a
        /// file is the one failure this must never commit.
        case suspiciouslyShort(was: Int, now: Int)
        case unchanged

        public var spoken: String {
            switch self {
            case .tooLarge(let b):
                return "That file is \(b / 1000)k — too big for a quick edit. Use the coding agent."
            case .empty:
                return "The edit came back empty, so I've left the file alone."
            case .suspiciouslyShort(let was, let now):
                return "The rewrite came back \(now) characters against \(was) — that looks "
                     + "truncated rather than edited, so I've left the file alone."
            case .unchanged:
                return "That came back identical, so there was nothing to write."
            }
        }
    }

    /// What the model is told. One file, one change, whole file back.
    ///
    /// It asks for the complete file rather than a diff on purpose. Diffs have to apply,
    /// and a diff that fails to apply at 2am is a silent no-op; a whole file either
    /// parses or it does not, and the check for that is one command.
    public static func prompt(task: String, path: String, contents: String) -> String {
        """
        Rewrite this one file to accomplish the change described. Output ONLY the \
        complete new contents of the file — no markdown fences, no commentary, no \
        explanation before or after.

        Keep everything you were not asked to change byte-identical, including comments, \
        blank lines and import order. Match the surrounding style. If the change cannot \
        be made correctly in this single file alone, output the file completely \
        unchanged rather than guessing.

        CHANGE: \(task)

        FILE: \(path)
        ---
        \(contents)
        """
    }

    /// Pulls the file back out of the reply.
    ///
    /// Models fence code even when told not to, and being strict about it would fail a
    /// perfectly good edit over three backticks.
    public static func extract(_ reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        lines.removeFirst()                                   // ``` or ```swift
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        text = lines.joined(separator: "\n")
        return text.trimmingCharacters(in: .newlines)
    }

    /// Whether the rewrite is safe to write over the original.
    public static func check(original: String, edited: String) -> Refusal? {
        if original.utf8.count > maxBytes { return .tooLarge(bytes: original.utf8.count) }
        let trimmed = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed == original.trimmingCharacters(in: .whitespacesAndNewlines) { return .unchanged }
        // Half a file is the shape a truncated generation takes. Deletions that big are
        // real but rare, and the agent can do them without this guess getting in the way.
        if original.count > 400, edited.count * 2 < original.count {
            return .suspiciouslyShort(was: original.count, now: edited.count)
        }
        return nil
    }

    /// The result of applying a rewrite to a file on disk.
    public struct Applied: Equatable {
        public let ok: Bool
        public let detail: String
        /// Where the original was kept, when the write stuck.
        public let backup: String?
    }

    /// Writes a rewrite to disk, proves it parses, and puts the original back if it does
    /// not.
    ///
    /// This lives in the core rather than beside the HTTP call so it can be tested, and
    /// these are the paths worth testing: a wrong answer from the model costs a retry, a
    /// failed revert costs the file. `runCheck` is injected for the same reason.
    public static func apply(reply: String, to path: String, original: String,
                             runCheck: (([String]) -> String?)? = nil) -> Applied {
        let edited = extract(reply)
        if let refusal = check(original: original, edited: edited) {
            return Applied(ok: false, detail: refusal.spoken, backup: nil)
        }

        // The original is kept before anything is touched. A quick edit that cannot be
        // undone quickly is not worth the time it saves.
        let backup = path + ".flowstate-backup"
        try? original.write(toFile: backup, atomically: true, encoding: .utf8)

        do {
            try edited.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return Applied(ok: false, detail: "Could not write \(path).", backup: nil)
        }

        if let cmd = syntaxCheck(for: path), let err = (runCheck ?? shellCheck)(cmd) {
            // Put it back. A rewrite that does not parse is not a smaller success than
            // one that does — it is a broken file, and leaving it for the next build to
            // find is the worst of both speeds.
            try? original.write(toFile: path, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: backup)
            return Applied(ok: false,
                           detail: "That edit didn't compile, so I put the file back. "
                                 + String(err.prefix(160)),
                           backup: nil)
        }
        return Applied(ok: true, detail: (path as NSString).lastPathComponent, backup: backup)
    }

    /// Runs a check command, returning its output only when it fails.
    ///
    /// A checker that is not installed is not the edit's fault, and not worth reverting a
    /// good rewrite over — so a launch failure reads as "no opinion", not "broken".
    public static func shellCheck(_ cmd: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = cmd
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        do { try p.run() } catch { return nil }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return nil }
        // 127 is `env` saying the checker is not installed, not the checker saying the
        // code is bad. Reading it as a failure meant a machine without node reverted
        // every good edit to a .js file and reported it as a compile error.
        if p.terminationStatus == 127 { return nil }
        return String(data: out, encoding: .utf8) ?? "check failed"
    }

    /// The command that proves the rewrite at least parses, chosen by extension.
    ///
    /// Not a build. A build of this app takes 23 seconds in release and the whole point
    /// of the fast lane is to be done before then; a parse costs milliseconds and catches
    /// the failure that actually happens, which is a model dropping a brace.
    ///
    /// nil means "no cheap check available" — the write still goes ahead, because
    /// refusing to edit a .md file for want of a parser would be worse.
    public static func syntaxCheck(for path: String) -> [String]? {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift":       return ["swiftc", "-parse", path]
        case "py":          return ["python3", "-m", "py_compile", path]
        case "js", "mjs":   return ["node", "--check", path]
        case "json":        return ["python3", "-c", "import json,sys; json.load(open(sys.argv[1]))", path]
        case "sh", "bash":  return ["bash", "-n", path]
        default:            return nil
        }
    }
}
