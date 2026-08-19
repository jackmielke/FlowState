#!/usr/bin/env swift
// Headless proof that the realtime transport works — NO microphone, NO speakers.
//   swift Scripts/verify-transport.swift
// Mints an ephemeral token, opens the WebSocket, sends the exact session.update
// shape the app sends, and asserts session.created + session.updated come back.
import Foundation

let model = "gpt-realtime-2.1"
let cfgURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/vibe-voice/config.json")

struct Cfg: Decodable { let OPENAI_API_KEY: String }
guard let d = try? Data(contentsOf: cfgURL),
      let key = try? JSONDecoder().decode(Cfg.self, from: d).OPENAI_API_KEY else {
    print("FAIL: no key at \(cfgURL.path)"); exit(1)
}

let sem = DispatchSemaphore(value: 0)
var sawCreated = false, sawUpdated = false, failure: String?

func mint() -> String? {
    var r = URLRequest(url: URL(string: "https://api.openai.com/v1/realtime/client_secrets")!)
    r.httpMethod = "POST"
    r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.httpBody = try! JSONSerialization.data(withJSONObject: ["session": ["type": "realtime", "model": model]])
    var out: String?
    let s = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: r) { data, resp, _ in
        defer { s.signal() }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let data,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            failure = "client_secrets HTTP \(code): \(String(data: data ?? Data(), encoding: .utf8) ?? "")"
            return
        }
        out = o["value"] as? String
    }.resume()
    s.wait()
    return out
}

guard let ek = mint() else { print("FAIL: \(failure ?? "mint failed")"); exit(1) }
print("PASS  client_secrets -> ek_…\(ek.suffix(4))")

var req = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!)
req.setValue("Bearer \(ek)", forHTTPHeaderField: "Authorization")
let task = URLSession.shared.webSocketTask(with: req)

func loop() {
    task.receive { result in
        switch result {
        case .failure(let e):
            failure = e.localizedDescription; sem.signal()
        case .success(let m):
            var text = ""
            if case .string(let s) = m { text = s }
            if case .data(let d) = m { text = String(data: d, encoding: .utf8) ?? "" }
            if let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
               let t = o["type"] as? String {
                switch t {
                case "session.created":
                    sawCreated = true
                    let id = (o["session"] as? [String: Any])?["id"] as? String ?? "?"
                    print("PASS  session.created  \(id)")
                    // exact shape from RealtimeClient.sendSessionUpdate
                    let upd: [String: Any] = ["type": "session.update", "session": [
                        "type": "realtime",
                        "instructions": "verification probe",
                        "output_modalities": ["audio"],
                        "audio": [
                            "input": [
                                "format": ["type": "audio/pcm", "rate": 24000],
                                "transcription": ["model": "gpt-4o-mini-transcribe"],
                                "noise_reduction": ["type": "near_field"],
                                "turn_detection": ["type": "server_vad", "threshold": 0.5,
                                                   "prefix_padding_ms": 300, "silence_duration_ms": 500,
                                                   "create_response": true, "interrupt_response": true]
                            ],
                            "output": ["format": ["type": "audio/pcm", "rate": 24000],
                                       "voice": "marin", "speed": 1.0]
                        ]]]
                    let js = String(data: try! JSONSerialization.data(withJSONObject: upd), encoding: .utf8)!
                    task.send(.string(js)) { _ in }
                case "session.updated":
                    sawUpdated = true
                    print("PASS  session.updated (session config accepted)")
                    sem.signal(); return
                case "error":
                    let msg = ((o["error"] as? [String: Any])?["message"] as? String) ?? text
                    failure = msg; sem.signal(); return
                default: break
                }
            }
            loop()
        }
    }
}
task.resume()
loop()

DispatchQueue.global().asyncAfter(deadline: .now() + 20) { failure = failure ?? "timeout"; sem.signal() }
sem.wait()
task.cancel(with: .goingAway, reason: nil)

if sawCreated && sawUpdated {
    print("\nRESULT: transport OK — no audio devices were opened.")
    exit(0)
} else {
    print("\nRESULT: FAILED — \(failure ?? "unknown"). created=\(sawCreated) updated=\(sawUpdated)")
    exit(1)
}
