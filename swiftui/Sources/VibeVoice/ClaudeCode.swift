import Foundation

/// Runs headless Claude Code (`claude -p`) and streams its progress back live.
///
/// Uses `--output-format stream-json`, which emits one JSON object per line as the run
/// proceeds: `system/task_summary` events carry human-readable labels ("Finding
/// OrbView.swift"), `assistant` events carry each tool call, and a final `result` event
/// carries the answer, cost and session id.
///
/// The session id is fed back via `--resume`, so a whole voice conversation maps onto
/// ONE Claude Code session and context survives between requests.
actor ClaudeCode {

    struct Result: Sendable {
        var ok: Bool
        var text: String
        var costUSD: Double?
        var turns: Int?
    }

    private var sessionID: String?
    /// The realtime model will happily fire a second tool call while waiting, and two
    /// runs resuming the same session id would race.
    private var busy = false

    var isBusy: Bool { busy }

    func resetSession() { sessionID = nil }

    /// A GUI .app inherits no shell PATH, so the usual install locations are checked
    /// explicitly before falling back to a login shell lookup.
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

    /// Turns one streamed line into a short human label, or nil if it isn't worth showing.
    private static func progressLabel(_ obj: [String: Any]) -> String? {
        switch obj["type"] as? String {
        case "system":
            // task_summary.detail is already written for humans — prefer it.
            if (obj["subtype"] as? String) == "task_summary",
               let d = obj["detail"] as? String, !d.isEmpty {
                return d
            }
            return nil

        case "assistant":
            guard let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]]
            else { return nil }
            for c in content where (c["type"] as? String) == "tool_use" {
                let name = (c["name"] as? String) ?? "tool"
                let input = c["input"] as? [String: Any] ?? [:]
                // Show the most identifying argument per tool, not the whole blob.
                if let path = (input["file_path"] as? String) ?? (input["path"] as? String) {
                    return "\(name) \((path as NSString).lastPathComponent)"
                }
                if let cmd = input["command"] as? String {
                    return "\(name): \(cmd.prefix(60))"
                }
                if let pattern = input["pattern"] as? String {
                    return "\(name): \(pattern.prefix(40))"
                }
                return name
            }
            return nil

        default:
            return nil
        }
    }

    /// - Parameter onProgress: called with a short label each time Claude Code does
    ///   something. Fires on a background executor; hop to the main actor to display.
    func run(task: String,
             repo: String,
             onProgress: @escaping @Sendable (String) -> Void) async -> Result {

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

        var args = ["-p", "--output-format", "stream-json", "--verbose",
                    "--permission-mode", "acceptEdits"]
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

        // Drain stderr concurrently — a run that fills the pipe buffer while nothing
        // reads it would deadlock.
        let errHandle = errPipe.fileHandleForReading
        async let errData = Task.detached { errHandle.readDataToEndOfFile() }.value

        do {
            try proc.run()
        } catch {
            return Result(ok: false, text: "Could not launch claude: \(error.localizedDescription)",
                          costUSD: nil, turns: nil)
        }

        var final: [String: Any]?
        do {
            for try await line in outPipe.fileHandleForReading.bytes.lines {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                if (obj["type"] as? String) == "result" { final = obj }
                if let label = Self.progressLabel(obj) { onProgress(label) }
            }
        } catch {
            // Stream ended early; fall through and report whatever the process said.
        }

        proc.waitUntilExit()
        let stderrText = String(decoding: await errData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let obj = final else {
            return Result(ok: false,
                          text: stderrText.isEmpty ? "Claude Code produced no result event."
                                                   : String(stderrText.suffix(400)),
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
