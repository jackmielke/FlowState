import Foundation

enum ConnectionState: Equatable {
    case idle
    case connecting
    case live
    case error(String)

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .live: return "Live"
        case .error: return "Error"
        }
    }
}

enum RealtimeEvent {
    case sessionCreated(String)
    case responseStarted
    case sessionUpdated
    case speechStarted
    case speechStopped
    case userTranscript(String)
    case assistantDelta(String)
    case assistantDone
    case audio(Data)
    case apiError(String)
    case closed(String)
    case toolCall(callID: String, name: String, argumentsJSON: String)
}

/// WebSocket transport for the realtime API (API-CONTRACT §2b).
/// wss://api.openai.com/v1/realtime?model=…  with `Authorization: Bearer <key|ek_>`
final class RealtimeClient: NSObject, @unchecked Sendable {

    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var closed = false

    /// Delivered on the main queue.
    var onEvent: ((RealtimeEvent) -> Void)?

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg, delegate: nil, delegateQueue: nil)
    }

    func connect(token: String, model: String) {
        closed = false
        var req = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = 32 * 1024 * 1024
        task = t
        t.resume()
        receiveLoop()
    }

    func disconnect() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    var isConnected: Bool { task != nil && !closed }

    // MARK: - Outbound

    private func sendRaw(_ text: String) {
        guard let task, !closed else { return }
        task.send(.string(text)) { [weak self] err in
            if let err { self?.emit(.apiError("send failed: \(err.localizedDescription)")) }
        }
    }

    func send(json obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return }
        sendRaw(s)
    }

    /// API-CONTRACT §"Session config" — note voice / turn_detection nest under `audio`.
    func sendSessionUpdate(_ s: AppSettings) {
        var input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": 24000],
            "noise_reduction": ["type": "near_field"],
            "turn_detection": [
                "type": "server_vad",
                "threshold": s.vadThreshold,
                "prefix_padding_ms": 300,
                "silence_duration_ms": Int(s.silenceDurationMs),
                "create_response": true,
                "interrupt_response": true
            ]
        ]
        if s.transcribeUser {
            input["transcription"] = ["model": "gpt-4o-mini-transcribe"]
        }
        var session: [String: Any] = [
            "type": "realtime",
            "instructions": s.devMode ? s.systemPrompt + "\n\n" + Self.devModeInstructions(repo: s.devRepo)
                                      : s.systemPrompt,
            "output_modalities": ["audio"],
            "audio": [
                "input": input,
                "output": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "voice": s.voice,
                    "speed": s.speed
                ]
            ]
        ]
        if s.devMode {
            session["tools"] = Self.devTools
            session["tool_choice"] = "auto"
        }
        send(json: ["type": "session.update", "session": session])
    }

    // MARK: - Dev Mode tools

    static func devModeInstructions(repo: String) -> String {
        """
        DEV MODE is on. You can change code on this Mac by calling dispatch_to_claude_code.
        The working repo is \(repo).

        Claude Code cannot hear this conversation, so `task` must be a complete,
        self-contained instruction — resolve "that", "it" and "the thing we just did"
        into explicit words before sending.

        Dispatching returns immediately, before the work is finished. Say briefly that
        you're on it, then STOP and wait. The result arrives later as a system message;
        summarise it in one or two sentences when it does. Never invent a result, and
        never read code aloud.
        """
    }

    static let devTools: [[String: Any]] = [[
        "type": "function",
        "name": "dispatch_to_claude_code",
        "description": "Send a coding task to Claude Code on the user's Mac. Use whenever the user asks to change, build, fix, explain or inspect code. Returns immediately; the result arrives later.",
        "parameters": [
            "type": "object",
            "properties": [
                "task": [
                    "type": "string",
                    "description": "A complete, self-contained instruction. No pronouns referring to the conversation."
                ]
            ],
            "required": ["task"]
        ]
    ]]

    /// Answers a tool call. `requestResponse` false lets the model speak without
    /// waiting for a second turn to be forced.
    func sendToolOutput(callID: String, output: [String: Any], requestResponse: Bool = true) {
        let json = (try? JSONSerialization.data(withJSONObject: output)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{}"
        send(json: [
            "type": "conversation.item.create",
            "item": ["type": "function_call_output", "call_id": callID, "output": json]
        ])
        if requestResponse { send(json: ["type": "response.create"]) }
    }

    /// Files a note as context and asks the model to speak it. Used to announce a
    /// long-running Claude Code task finishing, without blocking the voice loop.
    func sendSystemNote(_ text: String, requestResponse: Bool = true) {
        send(json: [
            "type": "conversation.item.create",
            "item": [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": text]]
            ]
        ])
        if requestResponse { send(json: ["type": "response.create"]) }
    }

    func appendAudio(_ pcm16: Data) {
        // Hand-built to skip a JSONSerialization pass on every 20 ms chunk.
        sendRaw(#"{"type":"input_audio_buffer.append","audio":""# + pcm16.base64EncodedString() + #""}"#)
    }

    /// API-CONTRACT §3 — image as a conversation item, then ask for a response.
    /// - Parameter requestResponse: when false the frame is added as silent context and
    ///   the model is NOT asked to reply. Continuous mode must use false: `response.create`
    ///   compels a response, so asking the model to "only speak up if something changed"
    ///   while also forcing a turn just makes it narrate "no meaningful change" forever.
    func sendImage(dataURI: String, prompt: String, requestResponse: Bool = true) {
        send(json: [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    ["type": "input_image", "image_url": dataURI],
                    ["type": "input_text", "text": prompt]
                ]
            ]
        ])
        if requestResponse {
            send(json: ["type": "response.create"])
        }
    }

    func cancelResponse() { send(json: ["type": "response.cancel"]) }

    // MARK: - Inbound

    private func receiveLoop() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                if !self.closed { self.emit(.closed(err.localizedDescription)) }
                self.closed = true
            case .success(let msg):
                switch msg {
                case .string(let s): self.handle(s)
                case .data(let d):   if let s = String(data: d, encoding: .utf8) { self.handle(s) }
                @unknown default: break
                }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "session.created":
            let sid = ((obj["session"] as? [String: Any])?["id"] as? String) ?? "?"
            FileHandle.standardError.write(Data("[realtime] session.created id=\(sid)\n".utf8))
            emit(.sessionCreated(sid))

        case "response.created":
            emit(.responseStarted)

        case "session.updated":
            FileHandle.standardError.write(Data("[realtime] session.updated\n".utf8))
            emit(.sessionUpdated)

        case "input_audio_buffer.speech_started":
            emit(.speechStarted)

        case "input_audio_buffer.speech_stopped":
            emit(.speechStopped)

        case "conversation.item.input_audio_transcription.completed":
            emit(.userTranscript((obj["transcript"] as? String) ?? ""))

        case "response.output_audio_transcript.delta", "response.audio_transcript.delta", "response.output_text.delta":
            emit(.assistantDelta((obj["delta"] as? String) ?? ""))

        case "response.output_audio.delta", "response.audio.delta":
            if let b64 = obj["delta"] as? String, let pcm = Data(base64Encoded: b64) {
                emit(.audio(pcm))
            }

        case "response.function_call_arguments.done":
            if let callID = obj["call_id"] as? String {
                emit(.toolCall(callID: callID,
                               name: (obj["name"] as? String) ?? "",
                               argumentsJSON: (obj["arguments"] as? String) ?? "{}"))
            }

        case "response.done":
            if let r = obj["response"] as? [String: Any],
               (r["status"] as? String) == "failed",
               let d = r["status_details"] as? [String: Any],
               let e = d["error"] as? [String: Any] {
                emit(.apiError((e["message"] as? String) ?? "response failed"))
            }
            emit(.assistantDone)

        case "error":
            let e = obj["error"] as? [String: Any]
            let msg = (e?["message"] as? String) ?? text
            FileHandle.standardError.write(Data("[realtime] ERROR \(msg)\n".utf8))
            emit(.apiError(msg))

        default:
            break
        }
    }

    private func emit(_ e: RealtimeEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(e) }
    }
}
