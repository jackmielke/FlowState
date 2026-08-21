import Foundation
import VibeVoiceCore

/// Notes worth rereading, written by a model.
///
/// The shipped placeholder was extractive: it picked load-bearing lines out of the
/// transcript, which is honest and offline but reads like "I said: …" quoted back. What
/// people actually want from a conversation summary is what Granola gives them — what it
/// was about, what got decided, what is still open, what happens next.
///
/// This costs about a third of a US cent per summary on `gpt-4.1-mini`, against a voice
/// session that costs cents per minute, so the price is not the interesting part. The
/// prompt is.
struct ModelSummarizer: Summarizer {

    let name = "gpt-4.1-mini"

    /// Falls back to this when there is no key or the call fails, so the feature never
    /// simply stops working. A worse summary beats a missing one.
    private let fallback = ExtractiveSummarizer()

    private static let model = "gpt-4.1-mini"

    /// Written against the failure modes the first drafts actually showed.
    ///
    /// - "First line, no heading" — it kept inventing a "### Meeting Notes:" title.
    /// - "OMIT any section" — it wrote "Open questions: none explicitly stated", which is
    ///   noise dressed as thoroughness.
    /// - "Never quote lines back" — the placeholder's whole failure mode, and the thing
    ///   the user noticed first.
    private static let system = """
    You write notes for a voice conversation between the user and their Mac assistant.

    Write what the user would want to reread in a month. Not a transcript.

    FORMAT — follow exactly:
    - First line: one plain sentence saying what the conversation was about. No heading, \
    no title, no bold.
    - Then only the sections that have real content, as `### Decisions`, \
    `### Open questions`, `### Next steps`.
    - OMIT any section entirely rather than writing "none" or "not discussed". An empty \
    section is noise.
    - Bullets, one line each.

    CONTENT:
    - Never quote lines back. Never write "I said", "the user said", "the assistant said".
    - Keep specifics: numbers, costs, file names, tool names, decisions. Drop pleasantries.
    - Something left unresolved goes under Open questions. Never invent closure.
    - Say what was DECIDED, not merely what was mentioned.
    - When a previous summary is supplied, CONTINUE it: fold in what is new, keep what \
    still stands, and do not restate the whole story.
    """

    func summarize(_ digest: SummaryDigest) async -> String? {
        guard let key = KeyStore.secret(forKey: "OPENAI_API_KEY") else {
            return await fallback.summarize(digest)
        }
        guard !digest.entries.isEmpty else { return nil }

        var user = ""
        if let previous = digest.previousSummary, !previous.isEmpty {
            user += "Previous summary of this same session:\n\(previous)\n\n"
        }
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        user += "Conversation — \(digest.entries.count) turns, "
        user += "\(clock.string(from: digest.from))–\(clock.string(from: digest.to)):\n\n"
        user += transcript(digest.entries)

        do {
            let text = try await complete(system: Self.system, user: user, key: key)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? await fallback.summarize(digest) : trimmed
        } catch {
            FileHandle.standardError.write(Data(
                "[summary] model call failed (\(error.localizedDescription)) — using the offline summariser\n".utf8))
            return await fallback.summarize(digest)
        }
    }

    /// Renders the turns as dialogue, oldest first, trimming from the FRONT when it gets
    /// long. The end of a conversation is where the decisions are; the beginning is where
    /// the throat-clearing is.
    private func transcript(_ entries: [ConversationEntry]) -> String {
        var lines: [String] = []
        for e in entries {
            let who: String
            switch e.speaker {
            case .user:      who = "user"
            case .assistant: who = "assistant"
            default:         who = "system"
            }
            let text = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append("\(who): \(text)")
        }
        // Roughly 100k characters is comfortably inside the model's window while leaving
        // room for the reply; a session that long is exactly the one worth summarising.
        var out = lines.joined(separator: "\n")
        if out.count > 100_000 {
            out = "[earlier turns omitted]\n" + String(out.suffix(100_000))
        }
        return out
    }

    private func complete(system: String, user: String, key: String) async throws -> String {
        var r = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        r.httpMethod = "POST"
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 45
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ])

        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            let m = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(code)"
            throw NSError(domain: "Summary", code: code, userInfo: [NSLocalizedDescriptionKey: m])
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "Summary", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no content in the reply"])
        }
        return content
    }
}
