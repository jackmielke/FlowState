import Foundation
import VibeVoiceCore

/// Looking things up on the web, out loud.
///
/// Uses OpenAI's own `web_search` tool through the Responses API rather than a separate
/// search provider. That matters for an app people are handed: it needs no second API
/// key, no second account and no second thing to explain in setup — the key already in
/// `KeyStore` does it.
///
/// The realtime voice model cannot call `web_search` itself; built-in tools belong to the
/// Responses API. So this is a native tool that makes that call and hands the answer
/// back, which also means the searching model can be a cheap one while the voice stays
/// on the expensive one.
enum WebSearch {

    /// Deliberately a small model. It is reading search results and summarising them, not
    /// reasoning, and it is in the path of a spoken answer where latency is the cost that
    /// actually shows.
    private static let model = "gpt-4.1-mini"

    private static let instructions = """
    You answer a spoken question using the web. The answer is about to be read aloud.

    - Two or three sentences. No lists, no headings, no markdown.
    - Lead with the answer, not with what you searched for.
    - Include dates and numbers when they are the point.
    - Name the source in passing when it matters ("according to the Swift blog"), but do \
    not read URLs aloud.
    - If the search did not settle it, say so plainly rather than padding.
    """

    static func search(_ query: String) async -> String {
        guard let key = KeyStore.secret(forKey: "OPENAI_API_KEY") else {
            return "No OpenAI key configured, so I can't search the web."
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "Nothing to search for." }

        var r = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        r.httpMethod = "POST"
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A search plus a summary is a few seconds. Beyond this the spoken conversation
        // has moved on and the answer is no longer worth waiting for.
        r.timeoutInterval = 30

        do {
            r.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "instructions": instructions,
                "tools": [["type": "web_search"]],
                "input": q,
            ])
            let (data, response) = try await URLSession.shared.data(for: r)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

            guard (200..<300).contains(code) else {
                let m = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(code)"
                if let action = BannerAction.forAPIError(m), action == .addCredits {
                    return "The search failed because the OpenAI account is out of credit."
                }
                return "The search failed: \(m)"
            }
            return shape(json) ?? "I searched but couldn't get a usable answer back."
        } catch {
            return "Couldn't reach the web: \(error.localizedDescription)"
        }
    }

    /// Pulls the spoken answer out, and one source to name if the model did not name one.
    private static func shape(_ json: [String: Any]) -> String? {
        guard let output = json["output"] as? [[String: Any]] else { return nil }

        var text = ""
        var firstSource: String?
        for item in output where (item["type"] as? String) == "message" {
            for part in (item["content"] as? [[String: Any]]) ?? [] {
                guard (part["type"] as? String) == "output_text" else { continue }
                text += (part["text"] as? String) ?? ""
                if firstSource == nil,
                   let a = (part["annotations"] as? [[String: Any]])?.first,
                   let title = a["title"] as? String, !title.isEmpty {
                    firstSource = title
                }
            }
        }

        // The API returns inline markdown citations — "([stackoverflow.com](https://…))" —
        // which are unreadable aloud. Strip them and, if that removed the only attribution,
        // put the source back as words.
        var spoken = text.replacingOccurrences(
            of: #"\s*\(\[[^\]]*\]\([^)]*\)\)"#, with: "", options: .regularExpression)
        spoken = spoken.replacingOccurrences(
            of: #"\s*\[[^\]]*\]\(https?://[^)]*\)"#, with: "", options: .regularExpression)
        spoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !spoken.isEmpty else { return nil }
        if let firstSource, !spoken.lowercased().contains(firstSource.lowercased().prefix(12)) {
            spoken += " (via \(firstSource))"
        }
        return spoken
    }
}
