import Foundation
import FlowStateCore

/// Runs a quick edit: one Anthropic call, one file written, one parse to prove it.
///
/// Deliberately not an agent. No tools, no loop, no subprocess — the whole cost is one
/// HTTP request, which is what makes this the fast lane. See `QuickEdit` for why the
/// scope is one file and what it refuses to do.
enum QuickEditRunner {

    struct Outcome: Sendable {
        let ok: Bool
        /// One sentence, meant to be said out loud.
        let spoken: String
        /// Where the original went, so a bad edit is one command from undone.
        let backup: String?
        let seconds: Double
    }

    /// The model. Sonnet 5 because it was measured faster than Haiku 4.5 on exactly this
    /// job AND got it right, which is not the order those two usually come in — at this
    /// size the latency is startup and round trip rather than tokens, so the cheaper
    /// model bought nothing and cost quality. Overridable in settings.
    static let defaultModel = "claude-sonnet-5"

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    enum Failure: LocalizedError {
        case noKey
        case http(Int, String)
        case refused(QuickEdit.Refusal)
        case unreadable(String)
        case brokeTheFile(String)

        var errorDescription: String? {
            switch self {
            case .noKey:
                return "I don't have an Anthropic API key yet. Add ANTHROPIC_API_KEY in "
                     + "Settings and I can make quick edits myself."
            case .http(let code, let body):
                return "The edit service said \(code): \(body.prefix(160))"
            case .refused(let r):     return r.spoken
            case .unreadable(let p):  return "I couldn't read \(p)."
            case .brokeTheFile(let e):
                return "That edit didn't compile, so I put the file back. \(e.prefix(160))"
            }
        }
    }

    /// The model call, injectable so the parts that can destroy a file — write, verify,
    /// revert — are testable without a network or a key. Those are the paths worth
    /// proving: a wrong answer costs a retry, a bad revert costs the file.
    typealias Ask = @Sendable (_ prompt: String) async throws -> String

    static func run(path rawPath: String, task: String, model: String? = nil,
                    ask askOverride: Ask? = nil) async -> Outcome {
        let started = Date()
        func done(_ ok: Bool, _ spoken: String, backup: String? = nil) -> Outcome {
            Outcome(ok: ok, spoken: spoken, backup: backup,
                    seconds: Date().timeIntervalSince(started))
        }

        let path = (rawPath as NSString).expandingTildeInPath
        guard let original = try? String(contentsOfFile: path, encoding: .utf8) else {
            return done(false, Failure.unreadable(path).localizedDescription)
        }
        if original.utf8.count > QuickEdit.maxBytes {
            return done(false, QuickEdit.Refusal.tooLarge(bytes: original.utf8.count).spoken)
        }
        let prompt = QuickEdit.prompt(task: task, path: path, contents: original)
        let reply: String
        do {
            if let askOverride {
                reply = try await askOverride(prompt)
            } else {
                guard let key = KeyStore.secret(forKey: "ANTHROPIC_API_KEY") else {
                    return done(false, Failure.noKey.localizedDescription)
                }
                reply = try await ask(key: key, model: model ?? defaultModel, prompt: prompt)
            }
        } catch {
            return done(false, error.localizedDescription)
        }

        let applied = QuickEdit.apply(reply: reply, to: path, original: original)
        guard applied.ok else { return done(false, applied.detail) }
        let secs = Date().timeIntervalSince(started)
        return done(true, String(format: "Done — %@ in %.1f seconds.", applied.detail, secs),
                    backup: applied.backup)
    }

    // MARK: - the one call

    private static func ask(key: String, model: String, prompt: String) async throws -> String {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 16000,
            "messages": [["role": "user", "content": prompt]],
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw Failure.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let blocks = json?["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined()
    }

}
