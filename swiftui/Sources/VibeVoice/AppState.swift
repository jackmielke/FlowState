import Foundation
import SwiftUI
import AppKit
import Combine
import VibeVoiceCore

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
    /// Live macOS Screen Recording state. Refreshed on launch, on app activation,
    /// before every capture, and on demand — never assumed from a past failure.
    @Published var screenPermission: ScreenPermission = .unknown
    @Published var showSettings = false
    @Published var lastCaptureNote: String?
    @Published var sessionID: String?
    @Published var devTaskRunning = false
    @Published var devTaskSummary: String?

    /// Mirrors of the response lifecycle, for the views. See `ResponseCoordinator`.
    @Published private(set) var responsePhase: ResponseCoordinator.Phase = .idle
    @Published private(set) var queuedResponses: Int = 0

    let audio = AudioEngine()
    let cost = CostMeter()
    let settingsStore = SettingsStore()
    private let client = RealtimeClient()
    private let claude = ClaudeCode()
    private var frameItemIDs: [String] = []
    /// The single owner of `response.create` / `response.cancel`. A create sent while a
    /// response is already running is rejected outright ("Conversation already has an
    /// active response in progress"), and this app can want a turn from four places at
    /// once — server VAD, a screenshot, a tool result, a Claude Code progress note — so
    /// the decision lives in exactly one place instead of at each call site.
    private let responses = ResponseCoordinator()
    /// Drives the coordinator's deadlines while a session is live.
    private var responseWatchdog: Timer?
    private var devStepBuffer: [String] = []
    private var devNarrateTimer: Timer?
    private var devSpokenUpdates = 0
    private var lastNarrationAt = Date.distantPast
    private var screenTimer: Timer?
    private var assistantIndex: Int?
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

        // The coordinator decides; the client is only ever the messenger.
        responses.send = { [weak self] out in
            guard let self else { return }
            switch out {
            case .create: self.client.createResponse()
            case .cancel: self.client.cancelResponse()
            }
        }
        responses.log = { [weak self] ev in self?.logResponse(ev) }
        responses.onChange = { [weak self] in self?.syncResponseState() }

        audio.onMicPCM = { [weak self] data in
            guard let self, self.client.isConnected else { return }
            self.client.appendAudio(data)
        }

        // Same gate as the on-screen button, so ⌘⇧2 and the button never disagree about
        // whether the app is accepting a new question.
        GlobalHotkey.shared.register { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard !self.hasQueuedResponse else {
                    self.note("A reply is already queued — ⌘⇧2 ignored until it goes out.")
                    return
                }
                await self.captureAndSend(auto: false)
            }
        }

        // Returning from System Settings is the moment the answer most often
        // changes, and macOS gives us no TCC change notification — so re-read on
        // every activation rather than trusting whatever we concluded last time.
        NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshScreenPermission(reason: "app-activated") }
            }
            .store(in: &bag)

        refreshScreenPermission(reason: "launch")
        // Get listed in Privacy & Security > Screen & System Audio Recording.
        //
        // On current macOS there is no "Allow" button for screen recording: the system
        // dialog only offers Open System Settings or Deny. An app appears in that list
        // once it has ATTEMPTED a capture and been refused — and it is the real
        // ScreenCaptureKit attempt that creates the record, not
        // CGRequestScreenCaptureAccess(), which returns false in ~10ms without
        // prompting. Measured on a never-before-seen bundle id: CGRequest returned
        // false instantly, while SCShareableContent returned -3801 "declined", which
        // is the refusal that registers the app.
        //
        // So: ask first (harmless, and correct if this Mac ever does prompt), then
        // make a genuine attempt so the row exists when the user goes looking for it.
        Task { @MainActor in
            var s = await ScreenCapture.ensureAccess(reason: "launch")
            if s != .granted {
                s = await ScreenCapture.probe(reason: "launch-register")
            }
            self.screenPermission = s
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
        stopResponseWatchdog()
        client.disconnect()
        audio.stop()
        connection = .idle
        sessionID = nil
        assistantIndex = nil
        // Local-only: the socket is gone, so nothing may be sent — and a request left
        // queued here would otherwise fire into the NEXT session.
        responses.reset(reason: "disconnect")
    }

    func applySettingsLive() {
        guard case .live = connection else { return }
        client.sendSessionUpdate(settings)
    }

    // MARK: - Response lifecycle

    /// True while a turn is being generated — the window in which a second
    /// `response.create` would be rejected by the API.
    var isResponding: Bool { responsePhase == .requested || responsePhase == .active }

    /// True while a cancel is in flight and has not been acknowledged.
    var isCancellingResponse: Bool { responsePhase == .cancelling }

    /// True when a turn has already been asked for and is waiting its turn to be sent.
    var hasQueuedResponse: Bool { queuedResponses > 0 }

    /// The user-facing Stop. Interrupts whatever is being generated and abandons
    /// anything queued behind it. Pressing it again while the cancel is unacknowledged
    /// forces the state back to idle, so the app can always be talked out of a stuck
    /// "busy" state without disconnecting.
    func stopResponse() {
        guard case .live = connection else {
            responses.reset(reason: "stop pressed while not live")
            return
        }
        responses.cancel(reason: "user pressed Stop")
    }

    /// Asks for a spoken turn. The ONLY way this app requests one.
    private func requestResponse(_ reason: String) {
        responses.request(reason: reason)
    }

    private func syncResponseState() {
        // Assign only on change: this runs from a 1 Hz watchdog, and an unconditional
        // write would republish (and redraw) every second for nothing.
        if responsePhase != responses.phase { responsePhase = responses.phase }
        if queuedResponses != responses.queuedCount { queuedResponses = responses.queuedCount }
    }

    /// Every start, finish, cancel, timeout and recovery lands on stderr; the ones a
    /// user could otherwise mistake for the app going silent also land in the
    /// transcript. Routine chatter (queued/sent/started/finished) stays out of the UI.
    private func logResponse(_ ev: ResponseCoordinator.Event) {
        FileHandle.standardError.write(Data("[response] \(ev.line)\n".utf8))
        switch ev.kind {
        case .cancelRequested, .timedOut, .dropped, .recovered:
            transcript.append(TranscriptItem(speaker: .system, text: "Response \(ev.kind.rawValue): \(ev.detail)"))
        case .sent, .queued, .held, .started, .finished, .reset, .ignored:
            break
        }
    }

    private func startResponseWatchdog() {
        stopResponseWatchdog()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.responses.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        responseWatchdog = t
    }

    private func stopResponseWatchdog() {
        responseWatchdog?.invalidate()
        responseWatchdog = nil
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
            // A fresh conversation has no response running, whatever the last one left
            // behind — and this is the point where a stale queued request must not
            // survive into the new session.
            responses.reset(reason: "session \(id) created")
            startResponseWatchdog()
            note("Live · session \(id)")
            syncScreenTimer()

        case .responseStarted(let id):
            responses.responseCreated(id: id)

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
            // Server VAD is about to open a turn of its own for this utterance, so
            // nothing we have queued may go out until that has been and gone.
            responses.userSpeechStarted()

        case .speechStopped:
            userSpeaking = false
            responses.userSpeechStopped()

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

        case .responseDone(let status):
            closeAssistantTurn()
            // Releases the lock and flushes at most one deferred request. Runs for every
            // status, including cancelled and failed — a response that ends badly still
            // ends, and treating it as still-running is what leaves the app mute.
            responses.responseFinished(status: status)

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
            // Response-lifecycle errors are ours to repair, not the user's to read. The
            // coordinator re-takes the lock (or releases it) and re-queues whatever was
            // rejected; only errors it does not recognise reach the banner.
            if responses.apiError(msg) {
                note("Handled a response-lifecycle error: \(msg)")
            } else {
                banner = msg
                note("API error: \(msg)")
            }

        case .closed(let why):
            if case .live = connection {
                connection = .error("Disconnected: \(why)")
            } else if case .connecting = connection {
                connection = .error("Could not connect: \(why)")
            }
            audio.stop()
            stopScreenTimer()
            stopDevNarration()
            stopResponseWatchdog()
            responses.reset(reason: "socket closed: \(why)")
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
            requestResponse("tool-refused")
            return
        }
        guard name == "dispatch_to_claude_code" else {
            client.sendToolOutput(callID: callID,
                                  output: ["status": "error", "reason": "Unknown tool \(name)."])
            requestResponse("tool-unknown")
            return
        }

        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any]
        let task = (args?["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !task.isEmpty else {
            client.sendToolOutput(callID: callID,
                                  output: ["status": "error", "reason": "Empty task."])
            requestResponse("tool-empty-task")
            return
        }

        let repo = settings.devRepo
        devTaskRunning = true
        devTaskSummary = String(task.prefix(120))
        startDevNarration()
        transcript.append(TranscriptItem(speaker: .system, text: "→ Claude Code: \(task)"))

        // The response that produced this tool call is still running, so the spoken
        // reply gets deferred to its response.done rather than sent now.
        client.sendToolOutput(callID: callID, output: [
            "status": "dispatched",
            "note": "A Claude Code task is now RUNNING in \(repo). It keeps running until you "
                  + "receive a message saying it finished or failed. While it runs you will get "
                  + "progress notes; if the user asks what is happening, answer from the most "
                  + "recent note. Tell the user you're on it in a few words now."
        ])
        requestResponse("tool-dispatched")

        Task { [weak self] in
            guard let self else { return }
            let r = await self.claude.run(task: task, repo: repo) { label in
                // Fires on a background executor as Claude Code works.
                Task { @MainActor [weak self] in self?.appendDevStep(label) }
            }
            await MainActor.run {
                self.devTaskRunning = false
                self.devTaskSummary = nil
                self.stopDevNarration()
                self.devStepBuffer.removeAll()
                if let c = r.costUSD { self.cost.addClaudeCode(c) }
                // "~$X sub" not "$X": claude runs on the Max subscription here, so this
                // is subscription usage at list-price equivalent, not money charged.
                let cost = r.costUSD.map { String(format: " (~$%.2f sub)", $0) } ?? ""
                self.transcript.append(TranscriptItem(
                    speaker: .system,
                    text: (r.ok ? "✓ Claude Code" : "✗ Claude Code") + cost + ": " + r.text))
                let note = r.ok
                    ? "[Claude Code finished the task. Result: \(r.text)] Tell the user what changed, in one or two sentences."
                    : "[Claude Code FAILED. Error: \(r.text)] Tell the user it failed and why, briefly."
                self.client.sendSystemNote(note)
                self.requestResponse("claude-code-\(r.ok ? "finished" : "failed")")
            }
        }
    }

    /// Appends one live Claude Code step to the transcript, collapsing consecutive
    /// duplicates so a tool called repeatedly does not spam the view.
    private func appendDevStep(_ label: String) {
        devTaskSummary = label
        let line = "   · " + label
        if let last = transcript.last, last.speaker == .system, last.text == line { return }
        transcript.append(TranscriptItem(speaker: .system, text: line))
        // Buffered rather than sent per-step: Claude Code emits steps in bursts, and one
        // conversation item per step would flood the session for no benefit.
        devStepBuffer.append(label)
    }

    /// Starts the progress feed for a Claude Code run.
    ///
    /// Two separate things happen here, and keeping them separate is the point:
    ///
    /// - Every step is filed into the conversation as SILENT context (no response
    ///   requested). That costs a handful of text tokens and means the model can answer
    ///   "what are you doing?" at any moment, instead of knowing nothing until the run
    ///   ends.
    /// - Only every `devNarrateInterval` does it additionally ask for a spoken turn.
    ///   Each spoken update is real audio output, so this is the cost dial, and
    ///   `devNarrateMax` caps how many a single long task can produce.
    private func startDevNarration() {
        stopDevNarration()
        devStepBuffer.removeAll()
        devSpokenUpdates = 0
        lastNarrationAt = Date()

        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushDevSteps() }
        }
        RunLoop.main.add(t, forMode: .common)
        devNarrateTimer = t
    }

    private func stopDevNarration() {
        devNarrateTimer?.invalidate()
        devNarrateTimer = nil
    }

    private func flushDevSteps() {
        guard devTaskRunning, case .live = connection, !devStepBuffer.isEmpty else { return }

        // Keep the note short — the last few steps are what matter, not the whole log.
        let steps = devStepBuffer.suffix(6).joined(separator: "; ")
        devStepBuffer.removeAll()

        let elapsed = Date().timeIntervalSince(lastNarrationAt)
        // A progress update is the least important thing on this socket, so unlike a
        // finished result it is NOT queued behind a running response — if the model is
        // already talking, this update simply becomes silent context and the next one
        // gets its chance. `responses.isBusy` covers the create-in-flight window too,
        // which a plain "is a response streaming" flag does not.
        let maySpeak = settings.devNarrate
            && devSpokenUpdates < settings.devNarrateMax
            && elapsed >= settings.devNarrateInterval
            && !userSpeaking          // never talk over the user
            && !responses.isBusy
            && !responses.hasQueuedRequest

        if maySpeak {
            devSpokenUpdates += 1
            lastNarrationAt = Date()
            client.sendSystemNote(
                "[Claude Code is STILL RUNNING. Latest steps: \(steps)] Give the user a "
                + "one-sentence update on what it is doing right now. Plain language, no file "
                + "paths, no code. Do not repeat an earlier update.")
            requestResponse("claude-code-progress")
        } else {
            // Context only. The model now knows, and will say so if asked.
            client.sendSystemNote(
                "[Claude Code is STILL RUNNING. Latest steps: \(steps)] "
                + "Context only — do not reply to this message.")
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

    /// Cheap, non-prompting re-read of the live TCC state.
    @discardableResult
    func refreshScreenPermission(reason: String) -> ScreenPermission {
        let before = screenPermission
        let now = ScreenCapture.refresh(reason: reason)
        screenPermission = now
        if now.canCapture, before.blocksCapture {
            // The block cleared — drop its banner and resume watching if it was on.
            if banner == before.bannerText { banner = nil }
            note("Screen Recording permission is now granted.")
            syncScreenTimer()
        }
        return now
    }

    /// The "Check again" button: asks ScreenCaptureKit itself, not just TCC, so a
    /// process that is stale despite an on toggle is correctly named as such.
    func recheckScreenPermission() async {
        note("Re-checking Screen Recording permission…")
        let before = screenPermission
        // ensureAccess before probing: probing only reads state, while this is what
        // actually registers the app in the privacy list if it is not there yet.
        _ = await ScreenCapture.ensureAccess(reason: "user-recheck")
        let now = await ScreenCapture.probe(reason: "user-recheck")
        screenPermission = now
        switch now {
        case .granted:
            if banner == before.bannerText { banner = nil }
            note("Screen Recording is granted and this process can capture.")
            syncScreenTimer()
        case .needsRestart:
            banner = now.bannerText
            note("Screen Recording is granted, but this process was launched before the grant — relaunch to use it.")
        case .denied, .unknown:
            banner = now.bannerText
            note("Screen Recording is still \(now.logToken).")
        }
    }

    func openScreenPrivacySettings() { ScreenCapture.openPrivacySettings() }

    func relaunchForScreenPermission() { ScreenCapture.relaunch() }

    func captureAndSend(auto: Bool) async {
        // Permission FIRST, connection second. ensureAccess() is what fires
        // CGRequestScreenCaptureAccess() and therefore what puts Vibe Voice in the
        // Screen & System Audio Recording list at all. Gating it behind "must be
        // connected" created a deadlock: you cannot grant screen access until you
        // connect, but you naturally want to fix permissions before connecting, and
        // pressing Show screen while idle silently did nothing.
        let pre: ScreenPermission
        if auto {
            pre = refreshScreenPermission(reason: "pre-capture(auto)")
        } else {
            pre = await ScreenCapture.ensureAccess(reason: "pre-capture(manual)")
            screenPermission = pre
        }

        guard case .live = connection else {
            banner = pre.blocksCapture
                ? pre.bannerText
                : "Screen access is ready — hit Connect and I can look at your screen."
            if pre.blocksCapture { handleScreenBlock(pre, auto: auto) }
            return
        }
        if pre.blocksCapture {
            handleScreenBlock(pre, auto: auto)
            return
        }

        do {
            let frame = try await ScreenCapture.capture(maxWidth: CGFloat(settings.screenshotSize))
            screenPermission = .granted
            // Auto frames are context, not questions. They are filed silently so the
            // model simply knows what is on screen when you next speak to it.
            let prompt = auto
                ? "[Screen update — context only. Do not reply to this.]"
                : "Here's my screen. What do you see?"
            client.sendImage(dataURI: frame.dataURI, prompt: prompt)
            // The frame lands in the conversation either way. Only a MANUAL capture is
            // a question, and even then the turn is requested through the coordinator —
            // pressing ⌘⇧2 while the model is mid-sentence used to put a second
            // response.create straight on the wire, which is the exact rejection this
            // whole path now avoids.
            if !auto { requestResponse("screenshot") }
            transcript.append(TranscriptItem(
                speaker: .user,
                text: auto ? "Screen frame (auto)" : "Sent a screenshot",
                image: frame.thumbnail))
            lastCaptureNote = String(format: "%.0f KB", Double(frame.bytes) / 1024)
        } catch ScreenCaptureError.permissionDenied(let p) {
            screenPermission = p
            handleScreenBlock(p, auto: auto)
        } catch {
            banner = "Capture failed: \(error.localizedDescription)"
        }
    }

    /// Reports a permission block ONCE and stops the watch loop.
    ///
    /// The old code let the continuous-screen timer re-stamp "Screen Recording is
    /// off" every few seconds forever, which is what made the message keep coming
    /// back after the user had already fixed it. Nothing here re-fires on a timer:
    /// the state only changes on an explicit re-check, on app activation, or on a
    /// relaunch.
    private func handleScreenBlock(_ p: ScreenPermission, auto: Bool) {
        let wasWatching = screenTimer != nil
        if wasWatching {
            stopScreenTimer()
            note("Paused continuous screen — \(p.logToken). It resumes on its own once permission is usable.")
        }
        guard banner != p.bannerText else { return }   // don't re-stamp the same line
        banner = p.bannerText
        if !auto || !wasWatching { note("Screen Recording: \(p.logToken).") }
    }

    func syncScreenTimer() {
        stopScreenTimer()
        guard settings.continuousScreen, case .live = connection else { return }
        // Never start a loop that is only going to fail: a blocked permission would
        // just re-raise the same error on every tick.
        guard !screenPermission.blocksCapture else {
            note("Continuous screen stays paused until Screen Recording is usable (\(screenPermission.logToken)).")
            return
        }
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
