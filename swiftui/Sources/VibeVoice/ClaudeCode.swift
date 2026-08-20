import Foundation

/// Runs headless Claude Code (`claude -p`) as a subprocess and returns its result.
///
/// The session id from each run is fed back via `--resume`, so a whole voice
/// conversation maps onto ONE Claude Code session and context survives between
/// requests — "actually make that a bit faster" knows what "that" is.
actor ClaudeCode {

    struct Result: Sendable {
        var ok: Bool
        var text: String
        var costUSD: Double?
        var turns: Int?
    }

    private var sessionID: String?
    /// Guards against a second dispatch while one is still running. The realtime model
    /// will happily fire another tool call while it waits, and two `claude -p` runs
    /// resuming the same session id would race.
    private var busy = false

    var isBusy: Bool { busy }

    func resetSession() { sessionID = nil }

    /// Locates the `claude` binary. A GUI .app does not inherit the shell's PATH, so
    /// the usual install locations are checked explicitly before falling back to PATH.
    private static func binary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) { return p }

        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["sh", "-lc", "command -v claude"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        try? which.run()
        which.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    func run(task: String, repo: String) async -> Result {
        if busy {
            return Result(ok: false, text: "A previous task is still running — one at a time.",
                          costUSD: nil, turns: nil)
        }
        guard let bin = Self.binary() else {
            return Result(ok: false, text: "Could not find the `claude` CLI on this Mac.",
                          costUSD: nil, turns: nil)
        }

        busy = true
        defer { busy = false }

        var args = ["-p", "--output-format", "json", "--permission-mode", "acceptEdits"]
        if let sid = sessionID { args += ["--resume", sid] }
        args.append(task)

        let expanded = (repo as NSString).expandingTildeInPath
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        if FileManager.default.fileExists(atPath: expanded) {
            proc.currentDirectoryURL = URL(fileURLWithPath: expanded)
        }
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Read both pipes concurrently. A run that fills the 64 KB pipe buffer while
        // nothing is draining it would deadlock.
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        async let outData = Task.detached { outHandle.readDataToEndOfFile() }.value
        async let errData = Task.detached { errHandle.readDataToEndOfFile() }.value

        do {
            try proc.run()
        } catch {
            return Result(ok: false, text: "Could not launch claude: \(error.localizedDescription)",
                          costUSD: nil, turns: nil)
        }

        let stdoutData = await outData
        let stderrData = await errData
        proc.waitUntilExit()

        guard let obj = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any] else {
            let err = String(decoding: stderrData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Result(ok: false,
                          text: err.isEmpty ? "Claude Code returned no parseable output." : String(err.suffix(400)),
                          costUSD: nil, turns: nil)
        }

        if let sid = obj["session_id"] as? String { sessionID = sid }
        let isError = (obj["is_error"] as? Bool) ?? false
        let text = (obj["result"] as? String) ?? ""

        return Result(ok: !isError,
                      text: String(text.prefix(1500)),
                      costUSD: obj["total_cost_usd"] as? Double,
                      turns: obj["num_turns"] as? Int)
    }
}
