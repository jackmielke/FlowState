import Foundation
import VibeVoiceCore

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
    /// `response.created` — the server now has a response running.
    case responseStarted(id: String?)
    case sessionUpdated
    case speechStarted
    case speechStopped
    case userTranscript(String)
    case assistantDelta(String)
    /// `response.done` — carries `response.status` (completed / cancelled / failed / incomplete).
    case responseDone(status: String)
    case audio(Data)
    case apiError(String)
    case closed(String)
    case toolCall(callID: String, name: String, argumentsJSON: String)
    case usage([String: Any])
    /// An image item the server accepted, so old frames can be pruned from context.
    case imageItemCreated(String)
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
    /// - Parameter nativeTools: realtime schemas for the tools the app answers itself.
    func sendSessionUpdate(_ s: AppSettings, nativeTools: [[String: Any]] = []) {
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
        // Native tools answer in milliseconds; Dev Mode's dispatcher is appended only
        // when Dev Mode is on.
        let tools = nativeTools + (s.devMode ? Self.devTools : [])
        if !tools.isEmpty {
            session["tools"] = tools
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

        SEVERAL TASKS CAN RUN AT ONCE, each in a different repo. Every dispatch answers
        with a short id like T1 or T2 — use those ids when you talk about them ("task one
        finished, task two is still building"). Pass `repo` when the user names a
        different project; leave it out for the default.

        Two tasks may NOT run in the same repo at the same time: they overwrite each
        other's files mid-build. When that happens the new task is QUEUED, not refused —
        it starts by itself the moment the repo frees up, and reports back like any
        other. So never tell the user to wait, never offer to retry it later, and never
        ask them to pick a different repo for you: say in one sentence that it is queued
        and what it is behind. They can reorder or drop queued tasks in the tasks panel.

        A follow-up like "make it faster" continues the most recent task unless the user
        names one. If that task is still running, the follow-up queues behind it.
        """
    }

    static let devTools: [[String: Any]] = [[
        "type": "function",
        "name": "dispatch_to_claude_code",
        "description": "Send a coding task to Claude Code on the user's Mac. Use whenever the user asks to change, build, fix, explain or inspect code. Returns immediately with a short task id; the result arrives later. Several tasks can run at once in different repos, and a task for a repo that is already busy is queued and started automatically — so call this even when something else is running.",
        "parameters": [
            "type": "object",
            "properties": [
                "task": [
                    "type": "string",
                    "description": "A complete, self-contained instruction. No pronouns referring to the conversation."
                ],
                "label": [
                    "type": "string",
                    "description": "Two or three words naming this task, for the on-screen list. E.g. 'orb animation'."
                ],
                "repo": [
                    "type": "string",
                    "description": "Absolute or ~ path to the repo. Omit to use the default repo."
                ],
                "resume_task": [
                    "type": "string",
                    "description": "An existing task id (T1, T2…) to continue instead of starting a new one. Use for follow-ups like 'make that faster'."
                ]
            ],
            "required": ["task"]
        ]
    ]]

    // MARK: - Conversation items
    //
    // None of these ask for a response. Every `response.create` in this app goes
    // through ResponseCoordinator instead, because the API rejects a second create
    // while one response is running ("Conversation already has an active response in
    // progress") and only one place can safely know whether that is the case.

    /// Answers a tool call. Filing the output is always safe; asking for the spoken
    /// reply is not, since the response that produced the tool call is usually still
    /// running when this lands.
    func sendToolOutput(callID: String, output: [String: Any]) {
        let json = (try? JSONSerialization.data(withJSONObject: output)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{}"
        send(json: [
            "type": "conversation.item.create",
            "item": ["type": "function_call_output", "call_id": callID, "output": json]
        ])
    }

    /// Files a note as context. Used to announce a long-running Claude Code task
    /// finishing, without blocking the voice loop.
    func sendSystemNote(_ text: String) {
        send(json: [
            "type": "conversation.item.create",
            "item": [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": text]]
            ]
        ])
    }

    func appendAudio(_ pcm16: Data) {
        // Hand-built to skip a JSONSerialization pass on every 20 ms chunk.
        sendRaw(#"{"type":"input_audio_buffer.append","audio":""# + pcm16.base64EncodedString() + #""}"#)
    }

    /// API-CONTRACT §3 — files an image as a conversation item.
    ///
    /// The frame is context only. Whether the model should then speak is the caller's
    /// decision, made through ResponseCoordinator: continuous mode never asks (a forced
    /// turn makes the model narrate "no meaningful change" forever), and a manual
    /// screenshot does.
    func sendImage(dataURI: String, prompt: String) {
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
    }

    /// Asks for a spoken turn. CALL SITE RULE: only ResponseCoordinator may call this —
    /// a create sent while a response is running is rejected outright.
    func createResponse() {
        FileHandle.standardError.write(Data("[realtime] -> response.create\n".utf8))
        send(json: ["type": "response.create"])
    }

    /// Interrupts the running response. Same rule: only ResponseCoordinator calls it.
    func cancelResponse() {
        FileHandle.standardError.write(Data("[realtime] -> response.cancel\n".utf8))
        send(json: ["type": "response.cancel"])
    }

    /// Drops an item from the conversation. Used to evict stale screen frames so their
    /// image tokens stop being re-billed on every subsequent turn.
    func deleteItem(id: String) {
        send(json: ["type": "conversation.item.delete", "item_id": id])
    }

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
            let rid = (obj["response"] as? [String: Any])?["id"] as? String
            FileHandle.standardError.write(Data("[realtime] response.created id=\(rid ?? "?")\n".utf8))
            emit(.responseStarted(id: rid))

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

        // The event is `conversation.item.added` — `conversation.item.created` never
        // fires on this API version, which silently made frame pruning dead code.
        case "conversation.item.added":
            // Track image items so continuous mode can delete old frames. Without this
            // every frame stays in context forever and per-turn image tokens grow
            // linearly with session length — measured: 323 tokens for one frame, 646
            // once a second was sent.
            if let item = obj["item"] as? [String: Any],
               let id = item["id"] as? String,
               let content = item["content"] as? [[String: Any]],
               content.contains(where: { ($0["type"] as? String) == "input_image" }) {
                emit(.imageItemCreated(id))
            }

        case "response.done":
            let r = obj["response"] as? [String: Any]
            let status = (r?["status"] as? String) ?? "completed"
            if let u = r?["usage"] as? [String: Any] {
                emit(.usage(u))
            }
            if status == "failed",
               let d = r?["status_details"] as? [String: Any],
               let e = d["error"] as? [String: Any] {
                emit(.apiError((e["message"] as? String) ?? "response failed"))
            }
            FileHandle.standardError.write(Data("[realtime] response.done status=\(status)\n".utf8))
            // ALWAYS emitted, whatever the status — this is what releases the
            // one-response-at-a-time lock, so swallowing it on a failed or cancelled
            // response would wedge the app into permanent silence.
            emit(.responseDone(status: status))

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
