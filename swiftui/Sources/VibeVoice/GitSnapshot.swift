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

/// Recording what a task changed, so the work is visible to everyone who needs it.
///
/// Dev Mode used to edit the working tree and stop. That meant a session's worth of
/// changes could pile up locally, invisible to the user, to a Claude Code session working
/// in the same repo, and — because the cloud only ever sees the remote — completely
/// invisible to anything running off GitHub.
enum GitCommitter {

    struct Outcome {
        var committed: Bool
        var sha: String?
        var files: Int
        var branchRef: String?
        var pushed: Bool
        var note: String
    }

    /// Commits ONLY what the task changed, on the current branch.
    ///
    /// The snapshot taken before the task is what makes this precise: it captured the
    /// tree as it stood, including anything the user had already left uncommitted. So
    /// diffing against it yields exactly the task's own edits, and unrelated work in
    /// progress is not swept into the commit.
    ///
    /// It commits on the CURRENT branch rather than checking out a new one, because the
    /// point is that the work is immediately visible and buildable by whoever is in the
    /// repo. A named `refs/vantage/<task>` is written at the same commit, so each task
    /// still has its own handle to review or revert.
    static func commitTaskChanges(repo: String,
                                  taskID: String,
                                  label: String,
                                  summary: String,
                                  push: Bool) -> Outcome {
        guard GitSnapshot.isRepo(repo) else {
            return Outcome(committed: false, sha: nil, files: 0, branchRef: nil,
                           pushed: false, note: "not a git repo")
        }
        let snapRef = "refs/vantage/\(taskID)"
        guard !run(repo, ["rev-parse", "--verify", snapRef]).out.isEmpty else {
            return Outcome(committed: false, sha: nil, files: 0, branchRef: nil,
                           pushed: false, note: "no restore point to diff against")
        }

        // Stage everything briefly to see untracked files, read the difference against
        // the snapshot, then unstage. Note this clears a pre-existing staged set — an
        // accepted trade in a mode where the user is talking, not managing an index.
        _ = run(repo, ["add", "-A"])
        let changed = run(repo, ["diff", "--cached", "--name-only", snapRef]).out
        _ = run(repo, ["reset", "-q"])

        let paths = changed.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            return Outcome(committed: false, sha: nil, files: 0, branchRef: nil,
                           pushed: false, note: "task changed nothing")
        }

        let subject = "\(label) [\(taskID)]"
        let body = summary.split(separator: "\n").prefix(6).joined(separator: "\n")
        var args = ["commit", "-m", subject, "-m", body,
                    "-m", "Dispatched by voice through FlowState Dev Mode.", "--"]
        args += paths
        let c = run(repo, args)
        guard c.ok else {
            return Outcome(committed: false, sha: nil, files: paths.count, branchRef: nil,
                           pushed: false, note: "commit failed: \(c.err.prefix(160))")
        }

        let sha = run(repo, ["rev-parse", "--short", "HEAD"]).out
        // A handle per task, without moving anyone's working tree.
        let named = "vantage/\(taskID)-\(slug(label))"
        _ = run(repo, ["update-ref", "refs/heads/\(named)", "HEAD"])

        var pushed = false
        var note = "committed \(paths.count) file\(paths.count == 1 ? "" : "s") as \(sha)"
        if push {
            let hasRemote = !run(repo, ["remote"]).out.isEmpty
            if !hasRemote {
                note += ", not pushed (no remote)"
            } else {
                // Never force. A rejected push means someone else moved the branch, and
                // silently overwriting them would be far worse than saying so.
                let branch = run(repo, ["rev-parse", "--abbrev-ref", "HEAD"]).out
                let p = run(repo, ["push", "origin", branch])
                pushed = p.ok
                note += pushed ? ", pushed" : ", push failed: \(p.err.suffix(120))"
            }
        }
        return Outcome(committed: true, sha: sha, files: paths.count,
                       branchRef: named, pushed: pushed, note: note)
    }

    private static func slug(_ s: String) -> String {
        let allowed = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(allowed).split(separator: "-").prefix(4).joined(separator: "-")
    }

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
