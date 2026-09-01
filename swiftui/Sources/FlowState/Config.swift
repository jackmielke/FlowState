import Foundation

/// Reads the OpenAI key from ~/.config/vibe-voice/config.json at runtime.
/// The key is NEVER hardcoded and never leaves this process except as an
/// `Authorization` header to api.openai.com.
enum KeyStore {
    struct ConfigFile: Decodable { let OPENAI_API_KEY: String }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/vibe-voice/config.json")
    }

    enum KeyError: LocalizedError {
        case missingFile(String)
        case malformed(String)
        var errorDescription: String? {
            switch self {
            case .missingFile(let p): return "No API key found at \(p). Create it with {\"OPENAI_API_KEY\":\"sk-...\"}"
            case .malformed(let p):   return "Could not parse \(p) — expected {\"OPENAI_API_KEY\":\"sk-...\"}"
            }
        }
    }

    /// Writes a secondary credential into the same file, preserving everything else in
    /// it and keeping the file 0600. Used for the Notion token, so a user never has to
    /// open a terminal to connect a service.
    static func setSecret(_ value: String, forKey key: String) throws {
        let url = configURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var obj = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { obj.removeValue(forKey: key) } else { obj[key] = trimmed }

        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        // Re-assert 0600: an atomic write replaces the file, taking its mode with it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func secret(forKey key: String) -> String? {
        guard let d = try? Data(contentsOf: configURL),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let v = j[key] as? String, !v.isEmpty else { return nil }
        return v
    }

    static func load() throws -> String {
        let url = configURL
        guard let data = try? Data(contentsOf: url) else {
            throw KeyError.missingFile(url.path)
        }
        guard let cfg = try? JSONDecoder().decode(ConfigFile.self, from: data),
              !cfg.OPENAI_API_KEY.isEmpty else {
            throw KeyError.malformed(url.path)
        }
        return cfg.OPENAI_API_KEY
    }
}

/// Mints a short-lived `ek_` client secret (API-CONTRACT §1).
/// The legacy /v1/realtime/sessions endpoint is gone — do not resurrect it.
enum EphemeralToken {
    struct Response: Decodable {
        let value: String
        let expires_at: Double?
    }

    struct APIError: LocalizedError {
        let status: Int
        let body: String
        var errorDescription: String? { "OpenAI \(status): \(body)" }
    }

    static func mint(apiKey: String, model: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/realtime/client_secrets")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "session": ["type": "realtime", "model": model]
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw APIError(status: code, body: String(data: data, encoding: .utf8) ?? "<binary>")
        }
        return try JSONDecoder().decode(Response.self, from: data).value
    }
}
