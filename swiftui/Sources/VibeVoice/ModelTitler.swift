import Foundation
import VibeVoiceCore

/// Names a conversation the way a person would.
///
/// `SessionTitle` is extractive: it takes the first substantive thing the user said and
/// trims the throat-clearing off the front. That is honest, offline and testable, and it
/// produces titles that read like fragments of a sentence rather than names for anything
/// — the same failure the summariser had before it was given a model.
///
/// This asks for a name instead, from the summary when there is one and the opening turns
/// when there is not. It falls back to `SessionTitle` whenever there is no key, no
/// material or no answer, so a conversation is never nameless.
enum ModelTitler {

    static let name = "gpt-4.1-mini"
    private static let model = "gpt-4.1-mini"

    private static let system = """
    You name conversations for a list, like chat titles in a sidebar.

    Rules:
    - 2 to 6 words. Under 44 characters. No trailing period.
    - Name the SUBJECT, not the request. "Screen permission debugging", not "Help me fix \
    the screen permission".
    - No "conversation about", no "discussion of", no "chat regarding", no quotes.
    - Sentence case. Keep real names, tools and file names as written.
    - If the conversation covers several things, name the largest one.
    - If there is genuinely nothing to name yet, reply with exactly: UNTITLED

    Reply with the title alone. Nothing else.
    """

    /// - Parameters:
    ///   - summary: the running summary, when one exists — by far the best source.
    ///   - entries: the conversation, used when nothing has been summarised yet.
    /// - Returns: a title, or nil to leave the deterministic one in place.
    static func title(summary: String?, entries: [ConversationEntry]) async -> String? {
        guard let key = KeyStore.secret(forKey: "OPENAI_API_KEY") else { return nil }

        var material = ""
        if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            material = "Summary of the conversation:\n" + summary
        } else {
            // The opening turns are where the subject is announced. Later ones wander.
            let opening = entries
                .filter { $0.speaker == .user || $0.speaker == .assistant }
                .prefix(12)
                .map { "\($0.speaker == .user ? "user" : "assistant"): \($0.text)" }
                .joined(separator: "\n")
            guard !opening.isEmpty else { return nil }
            material = "Opening of the conversation:\n" + opening
        }
        if material.count > 6000 { material = String(material.prefix(6000)) }

        do {
            let raw = try await complete(system: system, user: material, key: key)
            return clean(raw)
        } catch {
            FileHandle.standardError.write(Data(
                "[title] model call failed (\(error.localizedDescription)) — keeping the generated title\n".utf8))
            return nil
        }
    }

    /// Models like to be helpful with quotes, trailing periods and the odd "Title:".
    /// The length ceilings are `SessionTitle`'s, so both sources obey one rule.
    static func clean(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "^(Title|Name)\\s*:\\s*", with: "",
                                   options: [.regularExpression, .caseInsensitive])
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ "))
        while t.hasSuffix(".") { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)

        guard !t.isEmpty, t.uppercased() != "UNTITLED" else { return nil }
        // A model that ignored the brief and wrote a sentence is worse than the
        // deterministic title, so refuse it rather than truncating into nonsense.
        let words = t.split(separator: " ")
        guard words.count <= SessionTitle.maxWords + 2 else { return nil }
        guard t.count <= SessionTitle.maxCharacters + 12 else { return nil }
        return t
    }

    private static func complete(system: String, user: String, key: String) async throws -> String {
        var r = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        r.httpMethod = "POST"
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 20
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0.2,
            "max_tokens": 24,
            "messages": [["role": "system", "content": system],
                         ["role": "user", "content": user]],
        ])
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            let m = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(code)"
            throw NSError(domain: "Title", code: code, userInfo: [NSLocalizedDescriptionKey: m])
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "Title", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no content"])
        }
        return content
    }
}
