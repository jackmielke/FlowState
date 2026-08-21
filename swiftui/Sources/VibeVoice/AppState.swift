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
    var at: Date = Date()
    /// The conversation this line belongs to — the realtime `session.created` id, or a
    /// locally minted one when nothing is connected. Carried on the view model as well
    /// as on the stored record so a line on screen can always be traced to the file it
    /// was written to.
    var sessionID: String?
    /// The durable record this line produced, or nil when privacy refused to keep it.
    /// The difference is visible: an unrecorded line is still shown, because the live
    /// transcript reports what was said rather than what was kept.
    var entryID: UUID?
}

@MainActor
final class AppState: ObservableObject {

    @Published var connection: ConnectionState = .idle
    @Published var transcript: [TranscriptItem] = []
    @Published var userSpeaking = false
    @Published var banner: String?
    /// Optional one-click fix rendered on the banner (e.g. "Add credits").
    @Published var bannerAction: BannerAction?
    /// The first error that actually explained something this session.
    ///
    /// Running out of credit kills the socket, so the real cause ("no credits
    /// remaining") is immediately followed by "send failed: socket is not connected"
    /// and "could not connect". Those arrive last, so naively they win the banner and
    /// the user is told the least useful thing — which is exactly what happened.
    private var terminalCause: (message: String, action: BannerAction?)?

    /// Transport symptoms of an earlier, real failure. Never worth showing on their own
    /// once something better is known.
    private static func isTransportNoise(_ m: String) -> Bool {
        let l = m.lowercased()
        return l.contains("socket is not connected")
            || l.contains("send failed")
            || l.contains("software caused connection abort")
            || l.contains("connection reset")
    }
    /// Live macOS Screen Recording state. Refreshed on launch, on app activation,
    /// before every capture, and on demand — never assumed from a past failure.
    @Published var screenPermission: ScreenPermission = .unknown
    @Published var showSettings = false
    /// First run, or any launch with no usable key — there is nothing to do without one.
    @Published var showWelcome = KeyStore.secret(forKey: "OPENAI_API_KEY") == nil
    /// Whether Dev Mode can work at all on this machine.
    @Published var claudeAvailability: ClaudeCode.Availability = ClaudeCode.availability()

    func refreshClaudeAvailability() { claudeAvailability = ClaudeCode.availability() }

    /// The Dev Mode offer, if one is warranted right now. See `DevModeHint`.
    @Published private(set) var devOffer: DevModeHint.Trigger?
    private var assistantTurns = 0
    private var lastUserSaid: String?

    private func reconsiderDevOffer() {
        devOffer = DevModeHint.offer(devModeOn: settings.devMode,
                                     dismissed: settings.devNudgeDismissed,
                                     assistantTurns: assistantTurns,
                                     lastUserTranscript: lastUserSaid)
    }

    func acceptDevOffer() {
        devOffer = nil
        if claudeAvailability == .ready {
            settings.devMode = true
            applySettingsLive()
            note("Dev Mode is on. Ask me to change something in \(settings.devRepo).")
        } else {
            showSettings = true    // it cannot be switched on yet; show them why
        }
    }

    func dismissDevOffer() {
        devOffer = nil
        settings.devNudgeDismissed = true
    }
    /// Every display Vantage could look at. Re-read on launch, on activation, and
    /// whenever macOS reports a display arriving or leaving.
    @Published var displays: [DisplayOption] = []
    /// The display the last frame actually came from — not the one that was requested.
    @Published var lastCaptureDisplay: String?
    /// Which display this window sits on, i.e. what "follow the active display" means at
    /// this instant. See `refreshActiveDisplay()`.
    @Published private var windowDisplayID: CGDirectDisplayID?
    @Published var lastCaptureNote: String?
    @Published var sessionID: String?
    @Published var devTaskRunning = false
    @Published var devTaskSummary: String?

    /// The summary panel — what has been written about this conversation, and the
    /// button that writes one now. See `SummaryService` / `SummaryJob`.
    @Published var showSummary = false
    @Published private(set) var isSummarizing = false
    /// The newest summary written this launch. Drives the button's caption, and is
    /// what the panel opens on.
    @Published private(set) var latestSummary: ConversationSummary?
    /// Why the last request produced nothing — shown in the panel rather than swallowed,
    /// because a button that silently does nothing is indistinguishable from a broken one.
    @Published private(set) var summaryProblem: String?

    /// Mirrors of the response lifecycle, for the views. See `ResponseCoordinator`.
    @Published private(set) var responsePhase: ResponseCoordinator.Phase = .idle
    @Published private(set) var queuedResponses: Int = 0

    let audio = AudioEngine()
    let cost = CostMeter()
    let settingsStore = SettingsStore()
    /// The durable transcript: what was said, when, in which session, and what the
    /// microphone looked like while it was said. Privacy is applied on the way in.
    let conversation = ConversationStore()
    /// Measures the utterance in progress. Metadata only — see `UtteranceRecorder`.
    private let utterance = UtteranceRecorder()
    /// Metadata for the utterance that just ended, waiting for its transcript to arrive
    /// on the socket. The two events are separate (`speech_stopped` then
    /// `input_audio_transcription.completed`, often a second apart), so the measurement
    /// has to be parked between them.
    private var pendingUtteranceAudio: UtteranceAudio?
    /// Rolling summaries of the conversation. See `SummaryService` / `SummaryJob`.
    private var summaries: SummaryService!
    private var summaryTimer: Timer?
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
    /// Several Claude Code jobs at once. The rules about how many, and what may run
    /// beside what, live in VibeVoiceCore where they are tested.
    let devTasks = DevTaskRegistry(maxConcurrent: 3)
    /// Ambient: goes true when nothing has happened for a while, so the UI can step out
    /// of the way and leave the scene. Any hover, any speech, any state change resets it.
    @Published private(set) var isAmbient = false
    private var lastActivity = Date()
    private var ambientTimer: Timer?

    /// Which light to paint the scene in — the local clock, or a pinned choice.
    var currentDaylight: Daylight {
        Daylight(rawValue: settings.daylightMode) ?? .now()
    }

    /// Applies the appearance the UI should actually be in: a painted backdrop forces
    /// dark, otherwise the user's own choice.
    /// (Re)binds the summon hotkey to whatever Settings now says.
    /// The menu-bar glyph. Says what Flow is doing at a glance, without colour, because
    /// the menu bar renders it as a template image.
    var menuBarSymbol: String {
        switch connection {
        case .live:       return devTaskRunning ? "waveform.badge.gearshape" : "waveform"
        case .connecting: return "waveform.badge.plus"
        case .error:      return "waveform.badge.exclamationmark"
        case .idle:       return "waveform.slash"
        }
    }

    func applySummonHotkey() {
        guard !settings.summonHotkey.isEmpty else {
            GlobalHotkey.shared.unregisterSummon()
            return
        }
        GlobalHotkey.shared.registerSummon(HotkeyCombo.named(settings.summonHotkey)) {
            Task { @MainActor in Summon.toggle() }
        }
    }

    func applyEffectiveAppearance() {
        if settings.backdrop.place != nil {
            AppearanceMode.dark.applyToApp()
        } else {
            settings.appearance.applyToApp()
        }
    }

    func noteActivity() {
        lastActivity = Date()
        if isAmbient { isAmbient = false }
    }

    private func startAmbientClock() {
        ambientTimer?.invalidate()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.settings.ambientMode else { return }
                // Never fade out mid-sentence — silence is the whole signal here.
                let busy = self.userSpeaking || self.audio.isPlayingAudio || self.devTaskRunning
                if busy { self.lastActivity = Date() }
                let idle = Date().timeIntervalSince(self.lastActivity) > 45
                if idle != self.isAmbient { self.isAmbient = idle }
                // Cheap, and keeps "Showing <screen>" honest as the pointer moves.
                if self.isFollowingActiveDisplay { self.refreshActiveDisplay() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ambientTimer = t
    }

    /// Tools answered natively, in-process, without Claude Code.
    let tools = ToolRegistry(specs: NativeTools.specs
                                  + NativeTools.taskControlSpecs
                                  + NativeTools.memorySpecs)

    /// Stops a running task. The subprocess gets SIGTERM; the run then falls out of its
    /// stream with no result event, which is reported as "Stopped."
    @discardableResult
    func cancelTask(_ id: String) async -> String {
        guard let t = devTasks.task(id) else { return "No task called \(id)." }

        // A queued task has touched nothing yet, so dropping it is free — and a queue
        // you cannot take something out of is a trap.
        if t.status == .queued {
            devTasks.cancel(id)
            transcript.append(TranscriptItem(speaker: .system,
                                             text: "■ \(id) \(t.label): taken out of the queue"))
            objectWillChange.send()
            return "Dropped \(id) (\(t.label)) from the queue. It never started, so there's nothing to undo."
        }

        guard t.status == .running else { return "\(id) isn't running." }
        let killed = await claude.cancel(taskID: id)
        devTasks.cancel(id)
        // Stopping a task frees its repo, which is exactly what something in the queue
        // may have been waiting for.
        startQueuedTasks()
        devTaskRunning = !devTasks.running.isEmpty
        transcript.append(TranscriptItem(speaker: .system, text: "■ \(id) \(t.label): stopped"))
        objectWillChange.send()
        return killed
            ? "Stopped \(id) (\(t.label)). Its edits so far are still on disk — say undo \(id) to roll them back."
            : "\(id) had already finished."
    }

    /// Rolls the repo back to the restore point taken before the task started.
    func undoTask(_ id: String) -> String {
        guard let t = devTasks.task(id) else { return "No task called \(id)." }
        if t.status == .running {
            return "\(id) is still running — stop it first, then undo."
        }
        if t.status == .queued {
            return "\(id) hasn't started yet, so there's nothing to undo. Say stop \(id) to drop it."
        }
        let msg = GitSnapshot.restore(repo: t.repo, taskID: id)
        transcript.append(TranscriptItem(speaker: .system, text: "↩ \(id): \(msg)"))
        objectWillChange.send()
        return msg
    }

    /// Turn a native tool on or off, persist it, and tell a live session immediately.
    func setToolEnabled(_ on: Bool, _ name: String) {
        tools.setEnabled(on, for: name)
        settings.disabledTools = tools.disabledNames
        applySettingsLive()
        objectWillChange.send()
    }
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
            guard let self else { return }
            // Metering happens whether or not the socket is up: the measurement is of
            // what the user said, and it is not the network's business. The samples are
            // not retained — `UtteranceRecorder` keeps a running total and nothing else.
            //
            // A second consumer of this stream (an on-device recogniser) would be added
            // right here; see `LocalTranscriber` for what it would need.
            self.utterance.ingest(pcm16: data)
            guard self.client.isConnected else { return }
            self.client.appendAudio(data)
        }

        // What the user has agreed to keep. Read once here, and re-applied whenever
        // Settings changes it — see `applyPrivacySettings()`.
        conversation.privacy = settings.privacy
        summaries = SummaryService(store: conversation, policy: settings.summaries)
        summaries.onSummary = { [weak self] summary, delivery in
            self?.handleSummary(summary, delivery)
        }
        // Every start and every end, including the ends that produce nothing — a button
        // that says "Summarising…" has to hear about the failures too.
        summaries.onActivity = { [weak self] in
            guard let self else { return }
            self.isSummarizing = self.summaries.isSummarizing
            self.objectWillChange.send()
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
                Task { @MainActor in
                    self?.refreshScreenPermission(reason: "app-activated")
                    await self?.refreshDisplays()
                }
            }
            .store(in: &bag)

        // Plugging a monitor in or out is the one moment the picker's contents are
        // guaranteed to be wrong, and it is the only display change macOS does tell us
        // about — so it is worth listening for rather than polling.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.refreshDisplays() }
            }
            .store(in: &bag)

        // Dragging the window to another monitor changes what "follow the active display"
        // captures. Without this the picker would keep naming the screen you left.
        NotificationCenter.default
            .publisher(for: NSWindow.didChangeScreenNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshActiveDisplay() }
            }
            .store(in: &bag)

        for name in settings.disabledTools { tools.setEnabled(false, for: name) }

        applySummonHotkey()
        startAmbientClock()

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
            await self.refreshDisplays()
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
        bannerAction = nil
        terminalCause = nil

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
        // One last summary of whatever was said since the previous one, before the
        // session id stops meaning anything. Fire-and-forget: it lands in the transcript
        // and the note file even though the socket is gone.
        summaries.summarizeNow()
        stopSummaryClock()
        utterance.discard()
        pendingUtteranceAudio = nil
        conversation.endSession()
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
        client.sendSessionUpdate(settings, nativeTools: tools.realtimeTools())
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
            // Entries are filed under the id the API knows this conversation by, so a
            // transcript on disk can be lined up with anything the API reports later.
            conversation.beginSession(id: id)
            summaries.begin(session: id)
            startSummaryClock()
            cost.startSession()
            client.sendSessionUpdate(settings, nativeTools: tools.realtimeTools())
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
            utterance.begin()
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
            // Parked until the transcript for this utterance arrives, which is a
            // separate event and usually about a second later.
            pendingUtteranceAudio = utterance.end()
            responses.userSpeechStopped()

        case .userTranscript(let t):
            let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                // The durable record first, because it is the one that can be refused:
                // whatever comes back is what was actually kept, redactions and all.
                let entry = conversation.record(speaker: .user,
                                                text: clean,
                                                source: .realtimeAPI,
                                                audio: pendingUtteranceAudio)
                transcript.append(TranscriptItem(speaker: .user,
                                                 text: clean,
                                                 sessionID: sessionID,
                                                 entryID: entry?.id))
                lastUserSaid = clean
                reconsiderDevOffer()
            }
            pendingUtteranceAudio = nil

        case .assistantDelta(let d):
            if let i = assistantIndex, i < transcript.count {
                transcript[i].text += d
            } else {
                transcript.append(TranscriptItem(speaker: .assistant, text: d, streaming: true))
                assistantIndex = transcript.count - 1
            }

        case .responseDone(let status):
            closeAssistantTurn()
            assistantTurns += 1
            reconsiderDevOffer()
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
                note("API error: \(msg)")
                let action = BannerAction.forAPIError(msg)
                // Don't let the socket dying on top of a real cause overwrite it.
                if terminalCause != nil && action == nil && Self.isTransportNoise(msg) {
                    break
                }
                // Out-of-credit is the error that actually stops a session, and the raw
                // API text does not tell you where to fix it. Offer the page directly.
                let friendly = BannerAction.explanation(for: msg) ?? msg
                if action != nil || terminalCause == nil {
                    terminalCause = (friendly, action)
                }
                bannerAction = action ?? bannerAction
                banner = friendly
            }

        case .closed(let why):
            // Prefer the cause we already know over the symptom the socket reports.
            let reason = terminalCause?.message
                ?? (Self.isTransportNoise(why) ? "The connection dropped." : why)
            if let c = terminalCause {
                banner = c.message
                bannerAction = c.action ?? bannerAction
            }
            if case .live = connection {
                connection = .error(reason)
            } else if case .connecting = connection {
                connection = .error(reason)
            }
            audio.stop()
            stopScreenTimer()
            stopDevNarration()
            stopResponseWatchdog()
            // Same close-out as a deliberate disconnect: a dropped socket ends the
            // conversation just as thoroughly, and leaving the clock ticking would keep
            // summarising a session that is over.
            summaries.summarizeNow()
            stopSummaryClock()
            utterance.discard()
            pendingUtteranceAudio = nil
            conversation.endSession()
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
        // Dev Mode gates ONLY the Claude Code dispatcher — native tools are unrelated
        // to it and must keep working with Dev Mode off.
        guard settings.devMode || tools.spec(name) != nil else {
            client.sendToolOutput(callID: callID,
                                  output: ["status": "refused", "reason": "Dev Mode is off."])
            requestResponse("tool-refused")
            return
        }
        // Native tools return fast enough to answer in this same turn, so there is no
        // dispatch-and-report-back dance — just run it and hand back the result.
        if let spec = tools.spec(name) {
            let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
            note("tool \(name)")
            Task { @MainActor in
                let result: String
                switch name {
                case "stop_task":
                    result = await self.cancelTask((args["task_id"] as? String) ?? "")
                case "undo_task":
                    result = self.undoTask((args["task_id"] as? String) ?? "")
                case "summarize_conversation":
                    result = self.summarizeSessionNow(showPanel: false)
                case "memory_status":
                    result = self.conversation.spokenStatus
                case "pause_recording":
                    result = self.setRecording(paused: true)
                case "resume_recording":
                    result = self.setRecording(paused: false)
                case "forget_conversation":
                    result = self.forgetThisConversation()
                default:
                    result = await NativeTools.run(name, args: args)
                }
                self.transcript.append(TranscriptItem(
                    speaker: .system, text: "⚒ \(spec.summary): \(result.prefix(160))"))
                self.client.sendToolOutput(callID: callID,
                                           output: ["status": "ok", "result": result])
                self.requestResponse("native-tool-\(name)")
            }
            return
        }

        guard name == "dispatch_to_claude_code" else {
            client.sendToolOutput(callID: callID,
                                  output: ["status": "error", "reason": "Unknown tool \(name)."])
            requestResponse("tool-unknown")
            return
        }

        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any]
        let instruction = (args?["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !instruction.isEmpty else {
            client.sendToolOutput(callID: callID,
                                  output: ["status": "error", "reason": "Empty task."])
            requestResponse("tool-empty-task")
            return
        }

        let repo = (args?["repo"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? settings.devRepo
        let label = (args?["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? String(instruction.prefix(40))
        let mode = settings.devPermissionMode

        // A follow-up ("make that faster") continues an existing conversation rather
        // than starting a fresh one that knows nothing about the earlier work.
        let resumeID = (args?["resume_task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let resuming = resumeID.flatMap { devTasks.task($0) }

        // Capacity and repo-exclusivity are still the registry's call — but the answer
        // to "not now" is a queue rather than a refusal. Two runs in one checkout shred
        // each other's builds, which is why the rule exists; making the user personally
        // wait for the first one is not what the rule was for.
        let blocker = devTasks.rejectionFor(repo: repo)
        let mayStartNow: Bool
        if let r = resuming {
            // Continuing a task that is STILL RUNNING would put a second `claude`
            // process under one task id — same repo, same session, both writing.
            switch (r.status, blocker) {
            case (.running, _):                 mayStartNow = false
            case (_, .none):                    mayStartNow = true
            case (_, .repoBusy(let id, _)):     mayStartNow = id == r.id
            case (_, .atCapacity):              mayStartNow = false
            }
        } else {
            mayStartNow = blocker == nil
        }

        guard mayStartNow else {
            let request = DevTaskRequest(instruction: instruction,
                                         permissionMode: mode,
                                         resumeTaskID: resuming?.id)
            let queuedTask = devTasks.enqueue(label: resuming?.label ?? label,
                                              repo: repo,
                                              request: request)
            let position = devTasks.queuePosition(queuedTask.id) ?? devTasks.queued.count
            let why = blocker?.queuedExplanation
                ?? "\(resuming?.id ?? "That task") is still running, so this follow-up is "
                 + "queued behind it and starts when it finishes."
            transcript.append(TranscriptItem(
                speaker: .system,
                text: "⋯ \(queuedTask.id) queued #\(position) · \(label) · \(repo): \(instruction)"))
            objectWillChange.send()

            client.sendToolOutput(callID: callID, output: [
                "status": "queued",
                "task_id": queuedTask.id,
                "position": position,
                "reason": why,
                "note": "Task \(queuedTask.id) is QUEUED at position \(position) and starts BY "
                      + "ITSELF as soon as it can. Tell the user in one sentence that it is "
                      + "queued and what it is waiting on. Do not offer to wait or to retry — "
                      + "it is automatic, and it reports back when it finishes like any other "
                      + "task. They can reorder the queue in the tasks panel."
            ])
            requestResponse("tool-queued")
            return
        }

        let task: DevTask
        if let r = resuming {
            task = r
            devTasks.reopen(r.id)
            transcript.append(TranscriptItem(speaker: .system,
                                             text: "→ \(r.id) (continuing): \(instruction)"))
        } else {
            task = devTasks.start(label: label, repo: repo)
            transcript.append(TranscriptItem(speaker: .system,
                                             text: "→ \(task.id) \(label) · \(repo): \(instruction)"))
        }
        objectWillChange.send()

        launchDevTask(task,
                      instruction: instruction,
                      mode: mode,
                      resumeSessionID: resuming?.claudeSessionID)

        client.sendToolOutput(callID: callID, output: [
            "status": "dispatched",
            "task_id": task.id,
            "repo": repo,
            "note": "Task \(task.id) is now RUNNING in \(repo). It keeps running until you receive "
                  + "a message saying it finished or failed. Other tasks may be running or queued "
                  + "too — refer to them by id. If the user asks what is happening, answer from the "
                  + "most recent progress note. Tell the user you're on it in a few words now."
        ])
        requestResponse("tool-dispatched")
    }

    /// Actually starts a job: restore point, process, progress feed, and the queue drain
    /// that follows it.
    ///
    /// Split out of the tool call because it now has two callers — a dispatch that could
    /// run immediately, and the queue starting the next task on its own minutes later.
    /// Both need identically the same before-and-after, and a queue whose jobs skipped
    /// the git snapshot would be a queue whose jobs cannot be undone.
    private func launchDevTask(_ task: DevTask,
                               instruction: String,
                               mode: String,
                               resumeSessionID: String?) {
        let taskID = task.id
        let label = task.label
        let repo = task.repo

        // Restore point BEFORE anything is touched, so "undo that" is one sentence.
        if GitSnapshot.take(repo: repo, taskID: taskID) == nil {
            note("\(taskID): no git repo at \(repo) — this task has no undo.")
        }

        devTaskRunning = true
        devTaskSummary = label
        startDevNarration()
        objectWillChange.send()

        Task { [weak self] in
            guard let self else { return }
            let r = await self.claude.run(taskID: taskID,
                                          task: instruction,
                                          repo: repo,
                                          permissionMode: mode,
                                          resumeSessionID: resumeSessionID) { step in
                Task { @MainActor [weak self] in self?.appendDevStep(step, taskID: taskID) }
            }
            await MainActor.run {
                self.devTasks.setSessionID(r.sessionID, for: taskID)
                self.devTasks.finish(taskID, ok: r.ok, result: r.text, deniedTools: r.deniedTools)

                // Record the work so it is visible beyond this Mac. Only on success:
                // committing a failed or permission-blocked run would put a half-finished
                // change into history and, worse, onto the remote.
                var commitNote = ""
                if r.ok && r.deniedTools.isEmpty && self.settings.devAutoCommit {
                    let out = GitCommitter.commitTaskChanges(
                        repo: repo, taskID: taskID, label: label,
                        summary: r.text, push: self.settings.devAutoPush)
                    if out.committed {
                        commitNote = " " + out.note
                        self.transcript.append(TranscriptItem(
                            speaker: .system,
                            text: "⎇ \(taskID): \(out.note)"
                                + (out.branchRef.map { " · \($0)" } ?? "")))
                    } else if out.note != "task changed nothing" {
                        self.transcript.append(TranscriptItem(
                            speaker: .system, text: "⎇ \(taskID): not committed — \(out.note)"))
                    }
                }
                self.devTasks.pruneFinished()
                if let c = r.costUSD { self.cost.addClaudeCode(c) }

                let mark = r.deniedTools.isEmpty ? (r.ok ? "✓" : "✗") : "⚠︎"
                self.transcript.append(TranscriptItem(
                    speaker: .system, text: "\(mark) \(taskID) \(label): " + r.text))

                // The freed repo (or slot) is exactly what the queue was waiting for, so
                // the next job starts here — before the summary of what just happened is
                // written, so that summary can say what is running now.
                let started = self.startQueuedTasks()

                let still = self.devTasks.running
                self.devTaskRunning = !still.isEmpty
                self.devTaskSummary = still.first?.label
                if still.isEmpty { self.stopDevNarration(); self.devStepBuffer.removeAll() }

                var note: String
                if !r.deniedTools.isEmpty {
                    let tools = r.deniedTools.joined(separator: ", ")
                    note = "[Task \(taskID) (\(label)) was BLOCKED from using: \(tools). It could not "
                        + "finish. Tell the user which tool was blocked and that they can turn on "
                        + "auto-allow in Settings under Dev Mode, then ask if they want you to retry.] "
                        + "Partial result: \(r.text)"
                } else if r.ok {
                    note = "[Task \(taskID) (\(label)) FINISHED. Result: \(r.text)"
                        + (commitNote.isEmpty ? "" : " Git:\(commitNote).")
                        + "] Tell the user what changed, in one or two sentences. If it was "
                        + "committed and pushed, say so in a few words. Name the task if "
                        + "others are still running."
                } else {
                    note = "[Task \(taskID) (\(label)) FAILED. Error: \(r.text)] Tell the user it failed "
                        + "and why, briefly."
                }
                if !started.isEmpty {
                    note += " The queue moved on by itself: "
                        + started.map { "\($0.id) (\($0.label))" }.joined(separator: ", ")
                        + " just started. Mention that in a few words."
                }
                let waiting = self.devTasks.queued
                if !waiting.isEmpty {
                    note += " Still queued: " + waiting.map(\.id).joined(separator: ", ") + "."
                }
                if !still.isEmpty {
                    note += " Still running: " + still.map { "\($0.id) (\($0.label))" }.joined(separator: ", ") + "."
                }
                self.client.sendSystemNote(note)
                self.requestResponse("claude-code-finished")
                self.objectWillChange.send()
            }
        }
    }

    /// Starts every queued task that may now run, and returns the ones that did.
    ///
    /// The registry decides what "may run" means — one job per repo, `maxConcurrent`
    /// overall — so this cannot start a second job in a checkout however it is called.
    @discardableResult
    private func startQueuedTasks() -> [DevTask] {
        var started: [DevTask] = []
        while let next = devTasks.startNextQueued() {
            guard let request = next.request else {
                // Cannot happen through `enqueue`, and if it ever did, a task stuck in
                // `running` with nothing running would be far worse than a failure.
                devTasks.finish(next.id, ok: false, result: "Lost what this task was meant to do.")
                continue
            }
            let resumeSession = request.resumeTaskID.flatMap { devTasks.task($0)?.claudeSessionID }
            transcript.append(TranscriptItem(
                speaker: .system,
                text: "▶ \(next.id) \(next.label) · \(next.repo): starting (was queued)"))
            launchDevTask(next,
                          instruction: request.instruction,
                          mode: request.permissionMode,
                          resumeSessionID: resumeSession)
            started.append(next)
        }
        if !started.isEmpty { objectWillChange.send() }
        return started
    }

    /// Reorders the queue. `-1` is sooner, `+1` is later.
    func moveQueuedTask(_ id: String, by delta: Int) {
        guard devTasks.moveQueued(id, by: delta) else { return }
        objectWillChange.send()
    }

    /// Appends one live Claude Code step to the transcript, collapsing consecutive
    /// duplicates so a tool called repeatedly does not spam the view.
    private func appendDevStep(_ label: String, taskID: String) {
        devTasks.addStep(label, to: taskID)
        devTaskSummary = label
        objectWillChange.send()
        let line = "   · \(taskID) " + label
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
        let live = devTasks.running
        let prefix = live.count > 1
            ? "(" + live.map { "\($0.id) \($0.label)" }.joined(separator: ", ") + ") "
            : ""
        let steps = prefix + devStepBuffer.suffix(6).joined(separator: "; ")
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
            let said = transcript[i].text.trimmingCharacters(in: .whitespaces)
            if said.isEmpty {
                transcript.remove(at: i)
            } else {
                // Recorded once, when the turn is complete — not per delta. A barge-in
                // closes the turn early, and the partial text is still what was spoken,
                // so it is still the truth of the conversation.
                let entry = conversation.record(speaker: .assistant,
                                                text: said,
                                                source: .assistantStream)
                transcript[i].sessionID = sessionID
                transcript[i].entryID = entry?.id
            }
        }
        assistantIndex = nil
    }

    private func note(_ s: String) {
        transcript.append(TranscriptItem(speaker: .system, text: s, sessionID: sessionID))
        FileHandle.standardError.write(Data("[app] \(s)\n".utf8))
    }

    // MARK: - Conversation memory

    /// Ticks the summariser. Slow on purpose — `SummaryJob` decides whether anything is
    /// due, and the answer is almost always no, so this only has to be often enough that
    /// a summary is not noticeably late.
    private func startSummaryClock() {
        stopSummaryClock()
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Never summarise into the middle of a turn: it competes for the moment
                // the app should be listening, and the last line is usually incomplete.
                let busy = self.userSpeaking || self.isResponding || self.audio.isPlayingAudio
                self.summaries.tick(busy: busy)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        summaryTimer = t
    }

    private func stopSummaryClock() {
        summaryTimer?.invalidate()
        summaryTimer = nil
    }

    /// A finished summary: onto the screen, into the note, and back into the model's
    /// context so it can refer to what was said an hour ago without the whole history
    /// still being on the wire.
    private func handleSummary(_ summary: ConversationSummary, _ delivery: SummaryService.Delivery) {
        var line = "✎ summary: " + summary.text
        if let receipt = delivery.noteReceipt { line += " (" + receipt + ")" }
        transcript.append(TranscriptItem(speaker: .system, text: line, sessionID: summary.sessionID))
        latestSummary = summary
        summaryProblem = nil
        isSummarizing = summaries.isSummarizing

        // Context only — filed WITHOUT asking for a spoken turn. A summary that made the
        // assistant start talking unprompted every few minutes would be a worse app.
        if delivery.fileIntoChat, case .live = connection {
            client.sendSystemNote(
                "[Running summary of this conversation so far: \(summary.text)] "
                + "Context only — do not reply to this message.")
        }
        objectWillChange.send()
    }

    // MARK: - The summary panel

    /// The session the Summary button acts on: the live one, or the last one recorded.
    var summarySession: String? { conversation.summarizableSessionID }

    /// Every summary held this launch, newest first. Not filtered to the current session
    /// on purpose — the reason to open this panel is usually to re-read the recap of a
    /// conversation that has already ended.
    var visibleSummaries: [ConversationSummary] { conversation.allSummaries }

    /// Enough has been said to be worth summarising, and the user is not mid-sentence.
    var canSummarizeSession: Bool {
        guard !isSummarizing, !userSpeaking, let id = summarySession else { return false }
        return conversation.conversationalCount(inSession: id) >= SummaryJob.minimumForRecap
    }

    var summaryButtonHelp: String {
        if isSummarizing { return "Writing a summary of this conversation…" }
        if userSpeaking { return "Finish what you're saying and it'll summarise the whole thing." }
        if settings.privacy.paused {
            return "Recording is paused, so there's nothing kept to summarise. Turn it back on in Settings."
        }
        guard let id = summarySession,
              conversation.conversationalCount(inSession: id) >= SummaryJob.minimumForRecap else {
            return "Talk for a bit first — there's nothing to summarise yet."
        }
        return "Summarise this conversation, save it as a note, and keep it here to re-read."
    }

    /// "Summarise what we've been talking about" — the button, and the spoken request.
    ///
    /// One implementation for both, so the two can never disagree about what "this
    /// conversation" means. Answers immediately; the summary itself lands a moment later
    /// through `handleSummary`.
    ///
    /// - Parameter showPanel: the button opens the panel, because "nothing happened" is
    ///   a worse answer than a panel saying why. A spoken request does not: the answer
    ///   is going to be read aloud, and a sheet appearing over an ambient scene because
    ///   somebody said a sentence is the app interrupting itself.
    @discardableResult
    func summarizeSessionNow(showPanel: Bool = true) -> String {
        if showPanel { showSummary = true }
        guard let id = summarySession else {
            summaryProblem = "Nothing has been recorded yet, so there's nothing to summarise."
            return summaryProblem!
        }
        let said = summaries.summarizeSession(id)
        isSummarizing = summaries.isSummarizing
        // A request that did not start is a request that was refused, and the reason is
        // the only useful thing to show.
        summaryProblem = isSummarizing ? nil : said
        objectWillChange.send()
        return said
    }

    /// Re-reads the privacy and summary settings after the user changes them. Called
    /// from Settings rather than observed, so the moment a switch is flipped is the
    /// moment it takes effect — including retention, which deletes on the way down.
    func applyPrivacySettings() {
        conversation.privacy = settings.privacy
        summaries.policy = settings.summaries
        conversation.purgeExpiredFiles()
        objectWillChange.send()
    }

    /// Deletes this conversation, on screen and on disk.
    @discardableResult
    func forgetThisConversation() -> String {
        guard let id = conversation.currentSessionID else {
            return "There's nothing recorded for this conversation."
        }
        let dropped = conversation.forget(session: id)
        transcript.removeAll { $0.sessionID == id && $0.speaker != .system }
        objectWillChange.send()
        return dropped > 0
            ? "Forgotten — \(dropped) line\(dropped == 1 ? "" : "s") deleted, and the file with them."
            : "Nothing was being kept for this conversation."
    }

    /// The voice-reachable privacy switch. Pausing takes effect on the next line
    /// recorded, which is the next thing either of us says.
    func setRecording(paused: Bool) -> String {
        settings.privacy.paused = paused
        applyPrivacySettings()
        return paused
            ? "Recording paused. Nothing else from this conversation will be kept until you say resume."
            : "Recording again. " + settings.privacy.summaryLine
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
            // The display list is empty while permission blocks capture, so this is the
            // first moment it can be populated at all.
            Task { await refreshDisplays() }
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
            await refreshDisplays()
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

    // MARK: - Which screen

    /// The saved pick, if it is still attached. `nil` means "follow the active display",
    /// which is both the default and where an unplugged pick lands.
    var selectedDisplay: DisplayOption? {
        guard settings.screenDisplayID != DisplayOption.followsActiveID else { return nil }
        return displays.first { $0.displayID == settings.screenDisplayID }
    }

    /// What the pick resolves to right now — the display a capture would actually use.
    var activeDisplay: DisplayOption? {
        if let picked = selectedDisplay { return picked }
        guard let id = windowDisplayID else { return displays.first }
        return displays.first { $0.displayID == id } ?? displays.first
    }

    var isFollowingActiveDisplay: Bool { settings.screenDisplayID == DisplayOption.followsActiveID }

    /// The id to hand the capture layer: the raw saved pick, not `selectedDisplay`.
    ///
    /// The two differ before the display list has loaded — the first seconds after launch,
    /// and any moment permission was blocked — and in that window `selectedDisplay` is nil
    /// while a perfectly valid pin is sitting in settings. Capture resolves an unattached
    /// id by falling back on its own, so the raw value is both safe and more faithful.
    private var requestedDisplayID: CGDirectDisplayID? {
        isFollowingActiveDisplay ? nil : settings.screenDisplayID
    }

    /// Re-reads which display this window is on.
    ///
    /// Published rather than computed on demand: `NSScreen.main` is not observable, so a
    /// label derived straight from it would keep showing the old screen after you drag
    /// the window to another one, right up until something unrelated redrew the view.
    func refreshActiveDisplay() {
        let id = ScreenCapture.activeDisplayID()
        if windowDisplayID != id { windowDisplayID = id }
    }

    /// Pick a display, or pass `nil` to go back to following the active one.
    ///
    /// Deliberately does not touch the watch timer: the interval and the on/off state are
    /// unchanged by this, and tearing the timer down would drop a frame for no reason.
    /// The next tick simply captures the newly chosen screen.
    func selectDisplay(_ displayID: CGDirectDisplayID?) {
        let target = displayID ?? DisplayOption.followsActiveID
        guard settings.screenDisplayID != target else { return }
        settings.screenDisplayID = target
        if let d = displays.first(where: { $0.displayID == target }) {
            note("Now showing \(d.name) (\(d.resolution)) when you ask about my screen.")
        } else {
            note("Now following whichever display Vantage is on.")
        }
    }

    /// Re-reads the attached displays and re-validates the saved pick against them.
    ///
    /// A saved display id is only meaningful while that display is attached — CoreGraphics
    /// reissues ids across unplug and reboot — so a pick that no longer matches anything is
    /// dropped back to the active display rather than left pointing at nothing. Silent when
    /// permission is blocked: the list is empty for a reason the permission card already
    /// explains, and clearing a valid pick over it would lose the user's choice.
    func refreshDisplays() async {
        refreshActiveDisplay()
        guard !screenPermission.blocksCapture else { return }
        let found = await ScreenCapture.displays()
        guard !found.isEmpty else {
            // The capture layer just contradicted what the UI is claiming — re-read
            // rather than leaving a stale "granted" on screen with an empty picker.
            refreshScreenPermission(reason: "display-scan")
            return
        }
        displays = found

        let picked = settings.screenDisplayID
        guard picked != DisplayOption.followsActiveID,
              !found.contains(where: { $0.displayID == picked })
        else { return }
        settings.screenDisplayID = DisplayOption.followsActiveID
        note("The screen you had picked is no longer attached — following the active display again.")
    }

    func captureAndSend(auto: Bool) async {
        // Permission FIRST, connection second. ensureAccess() is what fires
        // CGRequestScreenCaptureAccess() and therefore what puts Vantage in the
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

        // Re-read which screen the pointer is on immediately before capturing, so a frame
        // can never come from the screen you just left. Polling alone can lag a move.
        if isFollowingActiveDisplay { refreshActiveDisplay() }

        do {
            let frame = try await ScreenCapture.capture(
                displayID: requestedDisplayID,
                maxWidth: CGFloat(settings.screenshotSize))
            screenPermission = .granted
            // Auto frames are context, not questions. They are filed silently so the
            // model simply knows what is on screen when you next speak to it.
            //
            // The display is named in both prompts because with more than one screen the
            // model otherwise has no way to know it is being shown one of several, and
            // will happily answer "your screen" questions about the wrong one.
            let screen = displays.count > 1 ? " (\(frame.display.menuLabel))" : ""
            let prompt = auto
                ? "[Screen update\(screen) — context only. Do not reply to this.]"
                : "Here's my screen\(screen). What do you see?"
            client.sendImage(dataURI: frame.dataURI, prompt: prompt)
            // The frame lands in the conversation either way. Only a MANUAL capture is
            // a question, and even then the turn is requested through the coordinator —
            // pressing ⌘⇧2 while the model is mid-sentence used to put a second
            // response.create straight on the wire, which is the exact rejection this
            // whole path now avoids.
            if !auto { requestResponse("screenshot") }
            let label = displays.count > 1 ? " · \(frame.display.name)" : ""
            let caption = (auto ? "Screen frame (auto)" : "Sent a screenshot") + label
            // A manual capture is a turn — the user asked something by showing it, and a
            // summary that omits "they shared their screen" is missing the reason the
            // next three lines happened. Continuous-mode frames are not: one every few
            // seconds would bury the conversation in its own wallpaper.
            let entry = auto ? nil
                             : conversation.record(speaker: .user, text: caption, source: .app)
            transcript.append(TranscriptItem(
                speaker: .user,
                text: caption,
                image: frame.thumbnail,
                sessionID: sessionID,
                entryID: entry?.id))
            lastCaptureNote = String(format: "%.0f KB", Double(frame.bytes) / 1024)
            lastCaptureDisplay = frame.display.name
            // A pick that silently fell back (display unplugged between the pick and the
            // capture) is corrected here rather than left to lie in the picker.
            if let wanted = requestedDisplayID, wanted != frame.display.displayID {
                await refreshDisplays()
            }
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
        // Send a frame NOW, not one interval from now. A repeating Timer first fires
        // after its interval, so connecting with a 10s interval left the model blind for
        // ten seconds — long enough to ask "what am I looking at?" and be told nothing.
        Task { @MainActor [weak self] in await self?.captureAndSend(auto: true) }

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
