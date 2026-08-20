import Foundation
import SwiftUI
import AppKit
import Combine

enum Speaker { case user, assistant, system }

struct TranscriptItem: Identifiable {
    let id = UUID()
    let speaker: Speaker
    var text: String
    var image: NSImage?
    var streaming: Bool = false
    let at = Date()
}

@MainActor
final class AppState: ObservableObject {

    @Published var connection: ConnectionState = .idle
    @Published var transcript: [TranscriptItem] = []
    @Published var userSpeaking = false
    @Published var banner: String?
    @Published var screenPermissionDenied = false
    @Published var showSettings = false
    @Published var lastCaptureNote: String?
    @Published var sessionID: String?
    @Published var devTaskRunning = false
    @Published var devTaskSummary: String?

    let audio = AudioEngine()
    let cost = CostMeter()
    let settingsStore = SettingsStore()
    private let client = RealtimeClient()
    private let claude = ClaudeCode()
    private var frameItemIDs: [String] = []
    private var screenTimer: Timer?
    private var assistantIndex: Int?
    private var responseActive = false
    private var bag = Set<AnyCancellable>()

    var settings: AppSettings {
        get { settingsStore.settings }
        set { settingsStore.settings = newValue }
    }

    init() {
        // Re-publish nested object changes so views refresh.
        audio.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        settingsStore.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)

        client.onEvent = { [weak self] ev in self?.handle(ev) }

        audio.onMicPCM = { [weak self] data in
            guard let self, self.client.isConnected else { return }
            self.client.appendAudio(data)
        }

        GlobalHotkey.shared.register { [weak self] in
            Task { await self?.captureAndSend(auto: false) }
        }

        note("Ready. Hit Connect and just talk. ⌘⇧2 shows me your screen.")

    }

    // MARK: - Connect

    func toggleConnection() {
        if case .live = connection { disconnect() }
        else if case .connecting = connection { disconnect() }
        else { Task { await connect() } }
    }

    func connect() async {
        connection = .connecting
        banner = nil

        guard await AudioEngine.requestMicAccess() else {
            connection = .error("Microphone access denied. Enable it in System Settings › Privacy & Security › Microphone.")
            return
        }

        let key: String
        do { key = try KeyStore.load() }
        catch { connection = .error(error.localizedDescription); return }

        // Mint an ephemeral ek_ token; only that goes onto the socket.
        var token = key
        do {
            token = try await EphemeralToken.mint(apiKey: key, model: settings.model)
            note("Minted ephemeral token (ek_…\(token.suffix(4)))")
        } catch {
            note("Ephemeral mint failed (\(error.localizedDescription)) — using standard key.")
        }

        do { try audio.start() }
        catch { connection = .error("Audio: \(error.localizedDescription)"); return }

        client.connect(token: token, model: settings.model)
    }

    func disconnect() {
        stopScreenTimer()
        client.disconnect()
        audio.stop()
        connection = .idle
        sessionID = nil
        assistantIndex = nil
        responseActive = false
    }

    func applySettingsLive() {
        guard case .live = connection else { return }
        client.sendSessionUpdate(settings)
    }

    // MARK: - Events

    private func handle(_ ev: RealtimeEvent) {
        switch ev {
        case .sessionCreated(let id):
            sessionID = id
            connection = .live
            frameItemIDs.removeAll()
            cost.startSession()
            client.sendSessionUpdate(settings)
            note("Live · session \(id)")
            syncScreenTimer()

        case .responseStarted:
            responseActive = true

        case .sessionUpdated:
            break

        case .speechStarted:
            userSpeaking = true
            // Barge-in. The server already truncates its own response because
            // turn_detection.interrupt_response is true, so sending response.cancel
            // here just races it ("Cancellation failed: no active response found").
            // All we owe the user is dropping the audio still queued locally.
            if audio.isPlayingAudio {
                audio.flushPlayback()
                closeAssistantTurn()
            }

        case .speechStopped:
            userSpeaking = false

        case .userTranscript(let t):
            let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { transcript.append(TranscriptItem(speaker: .user, text: clean)) }

        case .assistantDelta(let d):
            if let i = assistantIndex, i < transcript.count {
                transcript[i].text += d
            } else {
                transcript.append(TranscriptItem(speaker: .assistant, text: d, streaming: true))
                assistantIndex = transcript.count - 1
            }

        case .assistantDone:
            responseActive = false
            closeAssistantTurn()

        case .audio(let pcm):
            audio.enqueue(pcm16: pcm)

        case .toolCall(let callID, let name, let argumentsJSON):
            handleToolCall(callID: callID, name: name, argumentsJSON: argumentsJSON)

        case .usage(let u):
            cost.add(usage: u, rates: Rates.of(settings.model))

        case .imageItemCreated(let id):
            frameItemIDs.append(id)
            let keep = settings.maxScreenFrames
            guard keep > 0 else { break }
            // Evict oldest frames. Every frame left in context is re-billed as image
            // tokens on EVERY later turn, so an unbounded history makes a long session
            // cost far more than the frame count suggests.
            while frameItemIDs.count > keep {
                client.deleteItem(id: frameItemIDs.removeFirst())
            }

        case .apiError(let msg):
            banner = msg
            note("API error: \(msg)")

        case .closed(let why):
            if case .live = connection {
                connection = .error("Disconnected: \(why)")
            } else if case .connecting = connection {
                connection = .error("Could not connect: \(why)")
            }
            audio.stop()
            stopScreenTimer()
            cost.endSession()
        }
    }

    // MARK: - Dev Mode

    /// Answers the tool call IMMEDIATELY, then does the work in the background.
    ///
    /// Claude Code routinely takes minutes. Blocking here would leave the voice session
    /// in dead silence for the whole run — so the model is told "dispatched" right away
    /// (it says "on it"), and the finished result is filed later as a new turn, which
    /// makes it announce the outcome unprompted.
    private func handleToolCall(callID: String, name: String, argumentsJSON: String) {
        guard settings.devMode else {
            client.sendToolOutput(callID: callID,
                                  output: ["status": "refused", "reason": "Dev Mode is off."])
            return
        }
        guard name == "dispatch_to_claude_code" else {
            client.sendToolOutput(callID: callID,
                                  output: ["status": "error", "reason": "Unknown tool \(name)."])
            return
        }

        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any]
        let task = (args?["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !task.isEmpty else {
            client.sendToolOutput(callID: callID,
                                  output: ["status": "error", "reason": "Empty task."])
            return
        }

        let repo = settings.devRepo
        devTaskRunning = true
        devTaskSummary = String(task.prefix(120))
        transcript.append(TranscriptItem(speaker: .system, text: "→ Claude Code: \(task)"))

        client.sendToolOutput(callID: callID, output: [
            "status": "dispatched",
            "note": "Work has started in \(repo). Tell the user you're on it in a few words, then wait for the result."
        ])

        Task { [weak self] in
            guard let self else { return }
            let r = await self.claude.run(task: task, repo: repo)
            await MainActor.run {
                self.devTaskRunning = false
                self.devTaskSummary = nil
                if let c = r.costUSD { self.cost.addClaudeCode(c) }
                let cost = r.costUSD.map { String(format: " ($%.2f)", $0) } ?? ""
                self.transcript.append(TranscriptItem(
                    speaker: .system,
                    text: (r.ok ? "✓ Claude Code" : "✗ Claude Code") + cost + ": " + r.text))
                let note = r.ok
                    ? "[Claude Code finished the task. Result: \(r.text)] Tell the user what changed, in one or two sentences."
                    : "[Claude Code FAILED. Error: \(r.text)] Tell the user it failed and why, briefly."
                self.client.sendSystemNote(note)
            }
        }
    }

    private func closeAssistantTurn() {
        if let i = assistantIndex, i < transcript.count {
            transcript[i].streaming = false
            if transcript[i].text.trimmingCharacters(in: .whitespaces).isEmpty {
                transcript.remove(at: i)
            }
        }
        assistantIndex = nil
    }

    private func note(_ s: String) {
        transcript.append(TranscriptItem(speaker: .system, text: s))
        FileHandle.standardError.write(Data("[app] \(s)\n".utf8))
    }

    // MARK: - Screen

    func captureAndSend(auto: Bool) async {
        guard case .live = connection else {
            banner = "Connect first — then I can look at your screen."
            return
        }
        do {
            let frame = try await ScreenCapture.capture(maxWidth: CGFloat(settings.screenshotSize))
            screenPermissionDenied = false
            // Auto frames are context, not questions. They are filed silently so the
            // model simply knows what is on screen when you next speak to it.
            let prompt = auto
                ? "[Screen update — context only. Do not reply to this.]"
                : "Here's my screen. What do you see?"
            client.sendImage(dataURI: frame.dataURI, prompt: prompt, requestResponse: !auto)
            transcript.append(TranscriptItem(
                speaker: .user,
                text: auto ? "Screen frame (auto)" : "Sent a screenshot",
                image: frame.thumbnail))
            lastCaptureNote = String(format: "%.0f KB", Double(frame.bytes) / 1024)
        } catch ScreenCaptureError.permissionDenied {
            screenPermissionDenied = true
            banner = "Screen Recording permission is off for Vibe Voice."
        } catch {
            banner = "Capture failed: \(error.localizedDescription)"
        }
    }

    func syncScreenTimer() {
        stopScreenTimer()
        guard settings.continuousScreen, case .live = connection else { return }
        let t = Timer(timeInterval: settings.screenInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.captureAndSend(auto: true) }
        }
        RunLoop.main.add(t, forMode: .common)
        screenTimer = t
    }

    private func stopScreenTimer() {
        screenTimer?.invalidate(); screenTimer = nil
    }

    var isWatching: Bool { screenTimer != nil }
}
