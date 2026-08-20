import Foundation

/// Notion, spoken.
///
/// Deliberately the REST API with an internal integration token rather than MCP. Notion's
/// MCP server needs a full OAuth flow, which is a project; an internal integration is one
/// token pasted once, and reaches exactly the pages you share with it. For a voice app
/// that wants an answer in under a second, that trade is easy.
///
/// Everything returned here is written to be read aloud: titles and prose, no ids, no
/// JSON, no markdown syntax.
enum Notion {

    static let version = "2022-06-28"

    /// Stored next to the OpenAI key, in a file outside the repo with 0600 on it.
    static var token: String? {
        guard let d = try? Data(contentsOf: KeyStore.configURL),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = j["NOTION_TOKEN"] as? String,
              !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var isConfigured: Bool { token != nil }

    private static let missingToken =
        "No Notion token yet. Create an internal integration at notion.so/my-integrations, "
        + "share the pages you want with it, then paste the token into Settings under Notion."

    // MARK: - Tools

    static func search(_ query: String) async -> String {
        guard let token else { return missingToken }
        let body: [String: Any] = [
            "query": query,
            "page_size": 8,
            // Newest first is almost always what someone means out loud.
            "sort": ["direction": "descending", "timestamp": "last_edited_time"],
        ]
        switch await post("https://api.notion.com/v1/search", token: token, body: body) {
        case .failure(let m): return m
        case .success(let json):
            let results = json["results"] as? [[String: Any]] ?? []
            guard !results.isEmpty else {
                return "Nothing in Notion matches \"\(query)\". Remember the integration only "
                     + "sees pages that have been shared with it."
            }
            let lines = results.prefix(8).enumerated().map { i, r in
                "\(i + 1). \(title(of: r))"
            }
            return "Found \(results.count) in Notion: " + lines.joined(separator: "; ")
        }
    }

    /// Reads a page's text. Takes a title so the user never has to say an id out loud —
    /// it searches, takes the best match, then reads it.
    static func read(_ titleOrID: String) async -> String {
        guard let token else { return missingToken }

        let id: String
        let name: String
        if let direct = normalisedID(titleOrID) {
            id = direct
            name = "that page"
        } else {
            switch await post("https://api.notion.com/v1/search", token: token,
                              body: ["query": titleOrID, "page_size": 1]) {
            case .failure(let m): return m
            case .success(let json):
                guard let first = (json["results"] as? [[String: Any]])?.first,
                      let pid = first["id"] as? String else {
                    return "Couldn't find a Notion page called \"\(titleOrID)\"."
                }
                id = pid
                name = title(of: first)
            }
        }

        switch await get("https://api.notion.com/v1/blocks/\(id)/children?page_size=50", token: token) {
        case .failure(let m): return m
        case .success(let json):
            let blocks = json["results"] as? [[String: Any]] ?? []
            let text = blocks.compactMap(plainText).filter { !$0.isEmpty }
            guard !text.isEmpty else { return "\(name) is empty, or has no readable text." }
            let joined = text.joined(separator: " ")
            return joined.count > 1500
                ? "\(name): " + joined.prefix(1500) + "… (there's more)"
                : "\(name): " + joined
        }
    }

    // MARK: - Shaping

    private static func title(of object: [String: Any]) -> String {
        // A page's title lives under whichever property has type "title"; a database has
        // a top-level title array. Both reduce to the same plain string.
        if let props = object["properties"] as? [String: Any] {
            for (_, v) in props {
                if let p = v as? [String: Any], (p["type"] as? String) == "title",
                   let arr = p["title"] as? [[String: Any]] {
                    let t = arr.compactMap { $0["plain_text"] as? String }.joined()
                    if !t.isEmpty { return t }
                }
            }
        }
        if let arr = object["title"] as? [[String: Any]] {
            let t = arr.compactMap { $0["plain_text"] as? String }.joined()
            if !t.isEmpty { return t }
        }
        return "Untitled"
    }

    /// Flattens one block to speakable text, ignoring the block-type zoo.
    private static func plainText(_ block: [String: Any]) -> String? {
        guard let type = block["type"] as? String,
              let body = block[type] as? [String: Any],
              let rich = body["rich_text"] as? [[String: Any]] else { return nil }
        let t = rich.compactMap { $0["plain_text"] as? String }.joined()
        guard !t.isEmpty else { return nil }
        // Say a list item as a list item; drop every other structural marker.
        return type.hasSuffix("list_item") ? "• " + t : t
    }

    /// Accepts a bare or dashed Notion id, and nothing else.
    private static func normalisedID(_ s: String) -> String? {
        let raw = s.replacingOccurrences(of: "-", with: "")
        guard raw.count == 32, raw.allSatisfy({ $0.isHexDigit }) else { return nil }
        return raw
    }

    // MARK: - HTTP

    private enum Outcome {
        case success([String: Any])
        case failure(String)
    }

    private static func post(_ url: String, token: String, body: [String: Any]) async -> Outcome {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = "POST"
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await send(r, token: token)
    }

    private static func get(_ url: String, token: String) async -> Outcome {
        await send(URLRequest(url: URL(string: url)!), token: token)
    }

    private static func send(_ request: URLRequest, token: String) async -> Outcome {
        var r = request
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(version, forHTTPHeaderField: "Notion-Version")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: r)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard (200..<300).contains(code) else {
                // Notion's own message is usually the most useful thing available.
                let m = (json["message"] as? String) ?? "HTTP \(code)"
                if code == 401 { return .failure("Notion rejected the token: \(m)") }
                return .failure("Notion said: \(m)")
            }
            return .success(json)
        } catch {
            return .failure("Couldn't reach Notion: \(error.localizedDescription)")
        }
    }
}
