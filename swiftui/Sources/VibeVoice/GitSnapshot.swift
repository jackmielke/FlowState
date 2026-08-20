import Foundation

/// A restore point taken before Claude Code touches a repo.
///
/// Dev Mode writes files without asking, so a misheard sentence can change code. That is
/// only acceptable if backing out is one sentence rather than git archaeology.
///
/// The snapshot is a real commit object, but it is NOT on any branch: it is written with
/// `commit-tree` and parked under `refs/vibevoice/<task>`. So history stays clean, no
/// branch is created, nothing is checked out, and the working tree is untouched at the
/// moment it is taken — while the full contents of every tracked file are recoverable.
enum GitSnapshot {

    struct Info {
        var ref: String
        var sha: String
    }

    static func isRepo(_ repo: String) -> Bool {
        !run(repo, ["rev-parse", "--is-inside-work-tree"]).out.isEmpty
    }

    /// Captures the current state of `repo`. Returns nil when it isn't a git repo, which
    /// is a fine outcome — the task still runs, it just has no undo.
    static func take(repo: String, taskID: String) -> Info? {
        guard isRepo(repo) else { return nil }

        // Stage everything so untracked and modified files both land in the tree object,
        // then immediately unstage. The working tree is never modified by any of this.
        _ = run(repo, ["add", "-A"])
        let tree = run(repo, ["write-tree"]).out
        guard !tree.isEmpty else { _ = run(repo, ["reset"]); return nil }

        let head = run(repo, ["rev-parse", "HEAD"]).out
        var args = ["commit-tree", tree, "-m", "vibe-voice snapshot before \(taskID)"]
        if !head.isEmpty { args += ["-p", head] }
        let snap = run(repo, args).out
        _ = run(repo, ["reset"])          // leave the index as we found it

        guard !snap.isEmpty else { return nil }
        let ref = "refs/vibevoice/\(taskID)"
        _ = run(repo, ["update-ref", ref, snap])
        return Info(ref: ref, sha: String(snap.prefix(8)))
    }

    /// Restores every tracked file to the snapshot. Files the task CREATED are not
    /// removed — deleting files that were never there before is a bigger promise than
    /// this should make silently, and the report says so.
    static func restore(repo: String, taskID: String) -> String {
        let ref = "refs/vibevoice/\(taskID)"
        guard isRepo(repo) else { return "\(repo) isn't a git repo, so there's nothing to undo." }
        guard !run(repo, ["rev-parse", "--verify", ref]).out.isEmpty else {
            return "No restore point for \(taskID)."
        }

        let changed = run(repo, ["diff", "--name-only", ref]).out
        guard !changed.isEmpty else { return "Nothing changed since \(taskID) started." }

        let r = run(repo, ["checkout", ref, "--", "."])
        if !r.ok { return "Undo failed: \(r.err.prefix(200))" }

        let files = changed.split(separator: "\n").count
        let added = run(repo, ["ls-files", "--others", "--exclude-standard"]).out
        var msg = "Reverted \(files) file\(files == 1 ? "" : "s") to before \(taskID)."
        if !added.isEmpty {
            let n = added.split(separator: "\n").count
            msg += " \(n) new file\(n == 1 ? "" : "s") were left in place — say the word and I'll list them."
        }
        return msg
    }

    static func discard(repo: String, taskID: String) {
        _ = run(repo, ["update-ref", "-d", "refs/vibevoice/\(taskID)"])
    }

    // MARK: -

    private static func run(_ repo: String, _ args: [String]) -> (ok: Bool, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: (repo as NSString).expandingTildeInPath)
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        do { try p.run() } catch { return (false, "", error.localizedDescription) }
        let od = o.fileHandleForReading.readDataToEndOfFile()
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0,
                String(decoding: od, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                String(decoding: ed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
