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

    let audio = AudioEngine()
    let settingsStore = SettingsStore()
    private let client = RealtimeClient()
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

        // Headless verification hook: VIBEVOICE_SELFTEST=1 auto-connects at launch
        // so the socket + audio pipeline can be proven from a terminal.
        if ProcessInfo.processInfo.environment["VIBEVOICE_SELFTEST"] == "1" {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                await self?.connect()
                if ProcessInfo.processInfo.environment["VIBEVOICE_SELFTEST_SCREEN"] == "1" {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    await self?.selfTestCapture()
                }
            }
        }
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
            let frame = try await ScreenCapture.capture()
            screenPermissionDenied = false
            let prompt = auto
                ? "This is my screen right now. Only speak up if something meaningfully changed or if I asked you to watch for something."
                : "Here's my screen. What do you see?"
            client.sendImage(dataURI: frame.dataURI, prompt: prompt)
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

    /// Verification helper — proves the ScreenCaptureKit path end to end.
    func selfTestCapture() async {
        do {
            let f = try await ScreenCapture.capture()
            note("screen capture OK — \(f.bytes / 1024) KB JPEG, thumb \(Int(f.thumbnail.size.width))x\(Int(f.thumbnail.size.height))")
        } catch {
            note("screen capture FAILED — \(error.localizedDescription)")
        }
        await captureAndSend(auto: false)
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
