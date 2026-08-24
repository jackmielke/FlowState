import SwiftUI
import AppKit
import VibeVoiceCore

struct ContentView: View {
    @ObservedObject var state: AppState

    private var mode: OrbMode {
        switch state.connection {
        case .error: return .error
        case .connecting: return .connecting
        case .idle: return .idle
        case .live:
            // The model talking outranks the gate — muting stops it hearing you, not
            // you hearing it, and an orb that ignored a reply in progress would be
            // reporting the wrong half of the conversation.
            if state.audio.outLevel > 0.004 { return .speaking }
            if state.isMicMuted { return .muted }
            if state.userSpeaking || state.audio.micLevel > 0.012 { return .listening }
            return .idle
        }
    }

    private var orbLevel: Float { max(state.audio.micLevel, state.audio.outLevel * 1.15) }

    /// The painted scenes are all dusk-to-night rooms, and the moving ones are darker
    /// still. Light chrome on top of one is not a style choice, it is unreadable — so a
    /// scene pins the UI dark regardless of the light/dark setting, which goes back to
    /// governing Midnight and Paper.
    private var sceneIsDark: Bool { state.settings.backdrop.isScene }

    /// Elapsed recording time, taken from the samples actually captured rather than the
    /// wall clock, so it reports the length of the file being written.
    private var recordingClock: String {
        let s = Int(state.recorder.duration)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var recordHelp: String {
        if state.isRecording { return "Stop recording and save it" }
        if let problem = state.recordingError { return problem }
        let mode = state.settings.captureMode
        let size = CaptureStorage.rateLabel(for: state.capturePlan(for: mode))
        // Only a live session makes it "this conversation". Without one this is a
        // recorder, and saying otherwise would promise a transcript that is not coming.
        let what = state.audio.running ? "this conversation" : "your screen and microphone"
        return mode == .audioOnly
            ? "Record \(state.audio.running ? "this conversation" : "your microphone") (\(size))"
            : "Record \(what) — \(mode.menuLabel.lowercased()), \(size)"
    }

    /// The record glyph, which says what would be captured. `record.circle` for audio is
    /// the one every previous build had, so audio-only looks exactly as it always did.
    private var recordSymbol: String {
        state.settings.captureMode == .audioOnly ? "record.circle" : "video.circle"
    }

    /// Picks what the next recording captures.
    ///
    /// Choosing a mode asks macOS for whatever it needs *now*, rather than at the moment
    /// the button is pressed — a camera prompt that appears three seconds into a
    /// recording is a prompt you dismiss, and then the recording has no camera in it.
    private var captureModeMenu: some View {
        Menu {
            ForEach(CaptureMode.allCases) { mode in
                Button {
                    state.settings.captureMode = mode
                    Task { await state.prepareCapture(for: mode) }
                } label: {
                    Label(mode.menuLabel + (mode == state.settings.captureMode ? "  ✓" : ""),
                          systemImage: mode.symbol)
                }
            }
            Divider()
            // The estimate, in the menu that decides it. Not a warning — just the number,
            // which is the thing anyone choosing between these four actually wants.
            Text(CaptureStorage.rateLabel(for: state.capturePlan(for: state.settings.captureMode)))
            if state.storageAdvice.isWarning { Text(state.storageAdvice.headline) }
            Divider()
            Button("Capture settings…") { state.showSettings = true }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 14)
        .help("What to capture — currently \(state.settings.captureMode.menuLabel.lowercased())")
        .accessibilityLabel("Capture mode")
        .accessibilityValue(state.settings.captureMode.menuLabel)
    }

    /// How much disk the recording in progress has used, and how alarmed to be about it.
    private var storageChip: some View {
        let advice = state.liveStorageAdvice
        return HStack(spacing: 3) {
            Image(systemName: advice.symbol).font(.system(size: 8.5))
            Text(advice.headline)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundStyle(advice.level == .critical ? Theme.badInk
                         : advice.level == .caution ? Theme.accentInk : Theme.textFaint)
        .help(advice.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage. " + advice.detail)
    }

    /// Which photo a rotating folder is on. Derived from the clock rather than a timer,
    /// so it advances on its own and survives a redraw without extra state.
    private var photoIndex: Int {
        let every = state.settings.photoRotateSeconds
        guard every >= 1 else { return 0 }
        return Int(Date().timeIntervalSinceReferenceDate / every)
    }

    /// True once the app has been left alone long enough to get out of its own way.
    private var ambientHidden: Bool {
        state.settings.ambientMode
            && state.isAmbient
            && state.settings.backdrop.isScene
    }

    private var accentForMode: Color {
        switch mode {
        case .speaking: return Theme.voice
        case .error: return Theme.bad
        case .listening: return Theme.accent
        default: return Theme.textDim
        }
    }

    private var appearance: Binding<AppearanceMode> {
        Binding(get: { state.settings.appearance },
                set: { state.settings.appearance = $0; $0.applyToApp() })
    }

    var body: some View {
        ZStack {
            if state.settings.backdrop == .midnight || state.settings.backdrop == .paper {
                VisualEffectBackground()
            LinearGradient(colors: [Theme.bg.opacity(0.94), Theme.bg.opacity(0.99)],
                           startPoint: .top, endPoint: .bottom)
            // faint accent wash from the top-left, so the flat field — near-black or
            // paper, depending on the theme — never reads as dead
            RadialGradient(colors: [accentForMode.opacity(0.10), .clear],
                               center: .init(x: 0.28, y: 0.18), startRadius: 0, endRadius: 620)
                    .animation(.easeInOut(duration: 0.6), value: mode)
            } else {
                BackdropView(backdrop: state.settings.backdrop,
                             imagePath: state.settings.backdropImagePath,
                             daylight: state.currentDaylight,
                             energy: Double(orbLevel),
                             rotationIndex: photoIndex,
                             motionStyle: state.settings.motionStyle,
                             motionIntensity: state.settings.motionIntensity,
                             motionAssets: state.settings.motionAssets)
                // Keep the mode tint, so the room still shifts colour when FlowState speaks.
                RadialGradient(colors: [accentForMode.opacity(0.14), .clear],
                               center: .init(x: 0.28, y: 0.18), startRadius: 0, endRadius: 620)
                    .animation(.easeInOut(duration: 0.6), value: mode)
            }

            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.hairline)
                HStack(spacing: 0) {
                    stage
                    Divider().overlay(Theme.hairline)
                    sidebar
                }
            }
            // Ambient: the chrome fades, the scene and the orb stay. Everything is still
            // live underneath — this hides the furniture, it does not stop the session.
            .opacity(ambientHidden ? 0 : 1)
            .allowsHitTesting(!ambientHidden)
            .animation(.easeInOut(duration: 1.1), value: ambientHidden)

            if ambientHidden {
                VStack {
                    Spacer()
                    Text("move the mouse to come back")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.35))
                        .padding(.bottom, 22)
                }
            }
            WindowConfigurator(appearance: state.settings.appearance).frame(width: 0, height: 0)
        }
        .onContinuousHover { _ in state.noteActivity() }
        .frame(minWidth: 940, minHeight: 620)
        .preferredColorScheme(sceneIsDark ? .dark : state.settings.appearance.colorScheme)
        .onAppear { state.applyEffectiveAppearance(); state.applyHUD(); state.applyCameraBubble(); state.applyCaptions(); state.startFollowingActiveDisplay() }
        .onChange(of: state.settings.backdrop) { _, _ in state.applyEffectiveAppearance() }
        .onChange(of: state.settings.appearance) { _, _ in state.applyEffectiveAppearance() }
        // Settings is its own window rather than a sheet: most of what it changes —
        // backdrop, appearance, the orb, the transcript — can only be judged while you
        // can still see the app, so it stays visible and live underneath. It was an
        // in-window pane moved by a DragGesture, which is why it felt glitchy; dragging a
        // view is not the same thing as moving a window. See SettingsWindowController.
        .onChange(of: state.showSettings) { _, open in state.applySettingsWindow(open) }
        .sheet(isPresented: $state.showWelcome) {
            WelcomeView(state: state) { state.showWelcome = false }
        }
        .sheet(isPresented: $state.showSummary) { SummaryView(state: state) }
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: 12) {
                Spacer().frame(width: 68) // traffic lights

                HStack(spacing: 8) {
                    Circle()
                        .fill(LinearGradient(colors: [Theme.accentSoft, Theme.accentDeep],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 9, height: 9)
                        .shadow(color: Theme.accent.opacity(0.7), radius: 6)
                    Text("FLOW")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .tracking(2.0)
                        .foregroundStyle(Theme.text.opacity(0.92))
                }

                statusPill

                if state.isWatching { watchingPill }

                // Two states worth seeing without opening Settings, because both mean
                // the app does something when you are not looking at it: one listens
                // when you have not spoken to it, the other speaks when you have not
                // asked. Anything that acts on its own says so on the face of the app.
                //
                // Always both, on or off. They were hidden when off at first, which made
                // them one-way doors: clicking to switch one off removed the only control
                // that could switch it back on, and the way back was Settings. A switch
                // that vanishes when you use it is not a switch.
                listeningPill
                proactivePill

                if state.devTaskRunning { codingPill }

                if responseLabel != nil { responsePill }

                Spacer()

                costReadout

                QualityToggle(mode: state.settings.qualityMode) { state.setQualityMode($0) }

                if state.isResponding || state.isCancellingResponse {
                    Button { state.stopResponse() } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help(state.isCancellingResponse
                          ? "Still stopping — click again to force the session back to idle"
                          : "Stop this reply")
                }

                // Mute, in the header rather than in the button row below, because it is
                // the one control that is worth reaching for while the app is in the
                // background of your attention — and the header is the row that stays
                // put while the panel underneath it changes.
                Button { state.toggleMicMute() } label: {
                    Image(systemName: MicMute.symbol(muted: state.isMicMuted))
                        .foregroundStyle(state.isMicMuted ? Theme.bad : Theme.textDim)
                }
                .buttonStyle(IconButtonStyle())
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .help(MicMute.help(muted: state.isMicMuted, live: state.connection == .live)
                      + " (⌘⇧M)")
                .accessibilityLabel(MicMute.label(muted: state.isMicMuted))

                Button {
                    state.isRecording ? { _ = state.stopRecording() }() : { _ = state.startRecording() }()
                } label: {
                    // The glyph names what would be captured, so the mode is visible
                    // without opening the menu next to it — the difference between an
                    // audio note and a screen recording is not something to discover
                    // afterwards, from the file size.
                    Image(systemName: state.isRecording ? "stop.circle.fill" : recordSymbol)
                        .foregroundStyle(state.isRecording ? Theme.bad : Theme.textDim)
                }
                .buttonStyle(IconButtonStyle())
                // Always live. Recording opens the microphone itself when no session
                // has — a screen recorder that first requires you to connect to OpenAI
                // has the product the wrong way round.
                .help(recordHelp)
                .accessibilityLabel(state.isRecording ? "Stop recording" : "Record")
                .accessibilityValue(state.settings.captureMode.menuLabel)

                // What to capture. A menu rather than four buttons: this is one choice
                // out of four, made rarely, and the header has no room for a segmented
                // control next to everything else in it.
                if !state.isRecording { captureModeMenu }

                if state.isRecording {
                    Text(recordingClock)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        // Amber while the clock has not moved: red-and-0:00 is the exact
                        // pair that used to mean "this is silently capturing nothing".
                        .foregroundStyle(state.recorder.duration > 0 ? Theme.bad : Theme.accentInk)
                        .help(state.recorder.duration > 0
                              ? "Seconds captured so far"
                              : "No audio has reached the recorder yet")

                    // How big it has got. Only while a video recording is running: a WAV
                    // is 48 kB a second and nobody has ever needed to watch one.
                    if state.recorder.capturePlan.mode.isVideo { storageChip }
                }

                Button { Task { await state.captureAndSend(auto: false) } } label: {
                    Image(systemName: "rectangle.dashed.badge.record")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(state.hasQueuedResponse)
                .opacity(state.hasQueuedResponse ? 0.45 : 1)
                .help(captureHelp)

                AppearanceToggle(mode: appearance)

                Button { state.showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(IconButtonStyle())
                    .help("Settings")
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 52)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(pillColor)
                .frame(width: 6, height: 6)
                .shadow(color: pillColor.opacity(0.9), radius: 5)
                .modifier(PulseIf(active: state.connection == .connecting))
            Text(pillLabel)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Theme.fill)
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1)))
    }

    /// Both of these are toggles, not badges — switchable in the moment either turns out
    /// to be wrong, mid-call or mid-recording, without going to find a checkbox.
    private var listeningPill: some View {
        let on = state.settings.wakeWord
        return Button {
            state.settings.wakeWord.toggle()
            state.applyWakeWord()
        } label: {
            statusPill("antenna.radiowaves.left.and.right", "HEY FLOW",
                       tint: Theme.accent.opacity(0.55), on: on)
        }
        .buttonStyle(.plain)
        .help(on ? "Listening for the wake phrase, on-device. Click to stop."
                 : "Not listening for the wake phrase. Click to start.")
        .accessibilityLabel("Wake phrase")
        .accessibilityValue(on ? "on" : "off")
    }

    private var proactivePill: some View {
        let on = state.settings.proactive
        return Button {
            state.settings.proactive.toggle()
        } label: {
            statusPill("bell.fill", "PROACTIVE", tint: Theme.voice.opacity(0.75), on: on)
        }
        .buttonStyle(.plain)
        .help(on ? "It will open a session to tell you when a task finishes. Click to stop."
                 : "It will wait to be asked. Click to let it speak up.")
        .accessibilityLabel("Proactive updates")
        .accessibilityValue(on ? "on" : "off")
    }

    /// On: filled, with its name. Off: the outline and the icon alone.
    ///
    /// Off has to stay legible enough to be found and clicked, and quiet enough that two
    /// switched-off pills are not two things shouting in a header that already has plenty
    /// in it. Dropping the word is what buys that — the icon holds the place, the tooltip
    /// says the rest.
    private func statusPill(_ symbol: String, _ text: String, tint: Color, on: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 8.5))
            if on {
                Text(text)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(0.8)
            }
        }
        .foregroundStyle(on ? Theme.onAccent : Theme.textFaint)
        .padding(.horizontal, on ? 8 : 6).padding(.vertical, 4)
        .background {
            if on { Capsule().fill(tint) }
            else { Capsule().strokeBorder(Theme.hairline, lineWidth: 1) }
        }
        .contentShape(Capsule())
        .animation(.easeOut(duration: 0.15), value: on)
    }

    private var watchingPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "eye.fill").font(.system(size: 8.5))
            Text(watchingLabel)
                .font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(0.8)
        }
        .foregroundStyle(Theme.onAccent)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Theme.accent.opacity(0.92)))
        .modifier(PulseIf(active: true))
        .help(watchingHelp)
    }

    /// Names the screen once there is more than one, so a pill that says something is
    /// being watched also says *what*.
    private var watchingLabel: String {
        let base = "WATCHING · \(Int(state.settings.screenInterval))s"
        guard state.displays.count > 1, let d = state.activeDisplay else { return base }
        return base + " · " + d.name.uppercased()
    }

    private var watchingHelp: String {
        guard let d = state.activeDisplay else {
            return "Sending a frame every \(Int(state.settings.screenInterval))s."
        }
        return "Sending a frame of \(d.name) every \(Int(state.settings.screenInterval))s."
    }

    /// Live spend for this session. Token counts come from response.done.usage, so the
    /// only estimated part is the per-million rate table in Cost.swift.
    @ViewBuilder
    private var costReadout: some View {
        if state.cost.turns > 0 {
            HStack(spacing: 5) {
                Text("$" + state.cost.formatted)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                if let pm = state.cost.usdPerMinute {
                    Text(String(format: "%.2f/min", pm))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .surface(8)
            .help(costBreakdown)
        }
    }

    private var costBreakdown: String {
        let c = state.cost
        return """
        \(c.turns) turns · \(state.settings.qualityMode.label) mode
        audio in \(c.audioIn) · out \(c.audioOut)
        text in \(c.textIn) · out \(c.textOut) · cached \(c.cachedIn)
        images \(c.imageIn) tokens (\(String(format: "$%.3f", c.imageUSD)))

        OpenAI API only — this is what you are billed for.
        """
    }

    /// The response lifecycle, made visible.
    ///
    /// Without this the one-response-at-a-time rule is invisible: a screenshot sent
    /// mid-reply is answered a few seconds later, and there is nothing on screen to say
    /// why. QUEUED is the honest version of that wait, and STOPPING says a cancel is
    /// out but unacknowledged — the state the Stop button can force out of.
    private var responseLabel: String? {
        if state.isCancellingResponse { return "STOPPING" }
        if state.hasQueuedResponse { return "QUEUED · \(state.queuedResponses)" }
        if state.isResponding { return "REPLYING" }
        return nil
    }

    private var responsePill: some View {
        HStack(spacing: 5) {
            Image(systemName: state.isCancellingResponse ? "stop.circle" : "waveform.circle")
                .font(.system(size: 8.5))
            Text(responseLabel ?? "")
                .font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(0.8)
        }
        .foregroundStyle(Theme.textDim)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Theme.fill)
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1)))
        .modifier(PulseIf(active: true))
        .help(captureHelp)
    }

    private var captureHelp: String {
        if state.hasQueuedResponse {
            return "A reply is already queued — it goes out as soon as the current one finishes."
        }
        if state.isResponding {
            return "Send a screenshot (⌘⇧2). FlowState is mid-reply, so the frame is filed now and answered next."
        }
        return "Send a screenshot (⌘⇧2)"
    }

    /// Claude Code runs for minutes with the voice loop idle, so this is the only
    /// on-screen proof that something is still happening.
    private var codingPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "curlybraces").font(.system(size: 8.5))
            Text(codingLabel)
                .font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(0.8)
        }
        .foregroundStyle(Theme.onDev)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Theme.dev))
        .modifier(PulseIf(active: true))
        .help(codingHelp)
    }

    /// The queue is counted here because a task that will run later is still work the
    /// user asked for, and the pill is the only place they might be looking.
    private var codingLabel: String {
        let waiting = state.devTasks.queued.count
        return waiting > 0 ? "CODING · +\(waiting)" : "CODING"
    }

    private var codingHelp: String {
        let running = state.devTaskSummary ?? "Claude Code is working"
        let waiting = state.devTasks.queued
        guard !waiting.isEmpty else { return running }
        return running + " · " + waiting.count.formatted() + " queued: "
             + waiting.map(\.label).joined(separator: ", ")
    }

    private var pillColor: Color {
        switch state.connection {
        case .live: return Theme.good
        case .connecting: return Theme.accent
        case .error: return Theme.bad
        case .idle: return Theme.textFaint
        }
    }
    private var pillLabel: String {
        switch state.connection {
        case .live: return "LIVE"
        case .connecting: return "CONNECTING"
        case .error: return "ERROR"
        case .idle: return "IDLE"
        }
    }

    // MARK: - Stage

    private var stage: some View {
        VStack(spacing: 0) {
            if let b = state.banner { banner(b) }
            if let r = state.lastRecording { savedRecordingCard(r) }
            if state.screenPermission.blocksCapture { screenPermissionCard }
            if case .error(let msg) = state.connection { banner(msg) }

            Spacer(minLength: 16)

            VoiceOrb(mode: mode, level: orbLevel)
                .frame(width: 340, height: 340)

            VStack(spacing: 9) {
                Text(headline)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .frame(height: 26)
                Text(subhead)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
                    .frame(height: 16)

                if let offer = state.devOffer {
                    DevOfferCard(trigger: offer,
                                 claudeReady: state.claudeAvailability == .ready,
                                 onAccept: { state.acceptDevOffer() },
                                 onDismiss: { state.dismissDevOffer() })
                        .padding(.top, 10)
                }

                if case .error = state.connection, let a = state.bannerAction {
                    Button(a.label) { NSWorkspace.shared.open(a.url) }
                        .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                        .padding(.top, 2)
                }
            }
            .padding(.top, 6)

            LevelMeter(history: state.audio.micHistory,
                       tint: state.isMicMuted ? Theme.bad
                                              : (mode == .speaking ? Theme.voice : Theme.accent))
                .padding(.top, 20)
                .opacity(state.audio.running ? 1 : 0.32)
                // A flat meter is ambiguous — it is what a working microphone in a quiet
                // room looks like too. This is the label that tells the two apart, and it
                // is why the meter is not simply hidden while muted: an empty space where
                // the meter was says nothing at all.
                .overlay {
                    if state.isMicMuted {
                        HStack(spacing: 5) {
                            Image(systemName: "mic.slash.fill").font(.system(size: 10))
                            Text("Muted").font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(Theme.bad)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.panel.opacity(0.92)))
                    }
                }
                .animation(.easeOut(duration: 0.16), value: state.isMicMuted)

            Spacer(minLength: 20)

            HStack(spacing: 10) {
                Button(connectLabel) { state.toggleConnection() }
                    .buttonStyle(PrimaryButtonStyle(tint: state.connection == .live ? Theme.bad : Theme.accent))

                // Screen capture lives in the header icon and ⌘⇧2 — it was here as well,
                // which made the busiest row in the app carry the same action twice.

                // The recap. Deliberately next to Connect rather than buried in a menu:
                // the moment it is wanted is the moment a conversation ends, which is
                // the moment you are already looking at this row.
                Button {
                    state.summarizeSessionNow()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: state.isSummarizing ? "ellipsis.bubble" : "text.append")
                            .font(.system(size: 11.5))
                        Text(state.isSummarizing ? "Summarising…" : "Summary")
                    }
                }
                .buttonStyle(GhostButtonStyle(tint: summaryTint))
                .disabled(!state.canSummarizeSession && !hasSummaries)
                .opacity(state.canSummarizeSession || hasSummaries ? 1 : 0.5)
                .help(state.summaryButtonHelp)

                if state.isResponding || state.isCancellingResponse {
                    Button {
                        state.stopResponse()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill").font(.system(size: 10.5))
                            Text(state.isCancellingResponse ? "Force stop" : "Stop")
                        }
                    }
                    .buttonStyle(GhostButtonStyle(tint: Theme.badInk))
                    .help(state.isCancellingResponse
                          ? "The cancel has not come back yet — click again to force the session back to idle"
                          : "Interrupt this reply")
                }

                Button {
                    state.settings.continuousScreen.toggle()
                    state.syncScreenTimer()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: state.settings.continuousScreen ? "eye.fill" : "eye")
                            .font(.system(size: 11.5))
                        Text(state.settings.continuousScreen ? "Watching" : "Watch")
                    }
                }
                .buttonStyle(GhostButtonStyle(tint: state.settings.continuousScreen ? Theme.accentInk : Theme.text))
            }

            // A status line, not a control — which is why it is quiet. It says what is
            // being shared, and it is still a menu if you want to change it, but it no
            // longer competes with the buttons above it for attention.
            if !state.displays.isEmpty {
                ScreenPicker(displays: state.displays,
                             active: state.activeDisplay,
                             followsActive: state.isFollowingActiveDisplay,
                             onSelect: { state.selectDisplay($0) })
                    .padding(.top, 12)
            }

            ModelVoiceBar(model: $state.settings.model,
                          voice: $state.settings.voice,
                          audioDetail: audioDetail,
                          onChange: { state.applySettingsLive() })
                .padding(.top, 14)

            Spacer(minLength: 14)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The negotiated audio format. It had its own line under the stage; it is now the
    /// tooltip of the row that took that spot, so the detail is one hover away instead
    /// of spending a line on something you read once.
    private var audioDetail: String {
        state.audio.running
            ? state.audio.formatDescription
            : "audio idle · nothing is captured until you connect"
    }

    private var headline: String {
        switch state.connection {
        case .idle: return "Ready when you are"
        case .connecting: return "Waking up…"
        case .error:
            // Name the actual problem. "Something broke" is true of everything and
            // useful for nothing.
            if state.bannerAction == .addCredits { return "Out of credits" }
            if state.bannerAction == .usageLimits { return "Rate limited" }
            return "Couldn't connect"
        case .live:
            if mode == .speaking { return "FlowState is speaking" }
            if state.userSpeaking { return "Listening…" }
            return "Just talk"
        }
    }

    private var subhead: String {
        switch state.connection {
        case .idle: return "Voice-first. Server VAD handles turn-taking — no push-to-talk."
        case .connecting: return "Minting an ephemeral token and opening the socket."
        case .error:
            if state.bannerAction == .addCredits {
                return "Add credit to your OpenAI account, then hit Connect again."
            }
            if state.bannerAction == .usageLimits {
                return "OpenAI is throttling this account — wait a moment, then reconnect."
            }
            return "The exact API message is above."
        case .live: return state.settings.voice + " · " + state.settings.model + (state.sessionID.map { " · \($0)" } ?? "")
        }
    }

    private var hasSummaries: Bool { !state.visibleSummaries.isEmpty }

    /// Amber once there is something to go back and read, plain otherwise — the button
    /// doubles as the way back into the panel.
    private var summaryTint: Color { hasSummaries ? Theme.accentInk : Theme.text }

    private var connectLabel: String {
        switch state.connection {
        case .live: return "Disconnect"
        case .connecting: return "Cancel"
        default: return "Connect"
        }
    }

    private func banner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(Theme.badInk)
                .padding(.top, 1)
            Text(msg)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text.opacity(0.92))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let a = state.bannerAction {
                Button(a.label) { NSWorkspace.shared.open(a.url) }
                    .buttonStyle(GhostButtonStyle(tint: Theme.accent))
            }
            Button { state.banner = nil; state.bannerAction = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.textFaint)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.bad.opacity(0.10))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.bad.opacity(0.30), lineWidth: 1)))
        .padding(.top, 14)
    }

    /// The panel a finished recording leaves behind — see `RecordingResultCard`, which
    /// is the same card Settings shows, so the two cannot drift apart.
    private func savedRecordingCard(_ r: SessionRecorder.Recording) -> some View {
        RecordingResultCard(file: r.described,
                            problem: state.recordingProblem(for: r.url),
                            onPlay: { state.play(r.url) },
                            onReveal: { state.reveal(r.url) },
                            onDismiss: { state.dismissLastRecording() })
            .padding(.top, 14)
    }

    /// Two genuinely different problems, so two genuinely different cards.
    /// Telling a user who has already granted the permission that it is "off" is
    /// the bug this exists to avoid.
    private var screenPermissionCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(state.screenPermission.title)
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)

            if state.screenPermission == .needsRestart {
                Text("You've allowed it — macOS just won't hand the permission to an app that was already running when you granted it. Relaunch FlowState and screen capture works immediately. Nothing else to change.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Relaunch FlowState") { state.relaunchForScreenPermission() }
                        .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                    Button("Check again") { Task { await state.recheckScreenPermission() } }
                        .buttonStyle(GhostButtonStyle())
                }
            } else {
                Text("Allow FlowState under Privacy & Security › Screen & System Audio Recording, then come back — the app re-checks every time you switch to it, and will tell you if a relaunch is needed.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Already checked in that list? This build was re-signed since you granted it, so macOS sees a different app. Toggle FlowState off and back on, or run:  tccutil reset ScreenCapture com.jackmielke.vibevoice")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Open Privacy Settings") { state.openScreenPrivacySettings() }
                        .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                    Button("Check again") { Task { await state.recheckScreenPermission() } }
                        .buttonStyle(GhostButtonStyle())
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.accent.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.accent.opacity(0.28), lineWidth: 1)))
        .padding(.top, 14)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Only takes space once there is something to show, so a plain voice
            // session keeps the full sidebar for the conversation.
            if !state.devTasks.tasks.isEmpty {
                TaskPanel(state: state)
                    .frame(maxHeight: 260)
                Divider().overlay(Theme.hairline)
            }

            // Which conversation this is, and the way into another one. It replaces a
            // "TRANSCRIPT" label that named what the user could already see.
            SessionBar(state: state)

            Divider().overlay(Theme.hairline)

            ZStack {
                TranscriptView(items: state.transcript)
                if state.transcript.count <= 1 {
                    VStack(spacing: 7) {
                        Image(systemName: "waveform")
                            .font(.system(size: 19, weight: .light))
                            .foregroundStyle(Theme.textFaint.opacity(0.5))
                        Text("Nothing said yet")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textFaint)
                        Text("Your words and FlowState's replies land here as you\ntalk, and stay here after a restart.")
                            .font(.system(size: 11))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.textFaint.opacity(0.7))
                    }
                    .allowsHitTesting(false)
                    .padding(.bottom, 40)
                }
            }
        }
        .frame(width: 372)
        .background(Theme.sidebar)
    }
}

private struct PulseIf: ViewModifier {
    var active: Bool
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(active ? (on ? 0.35 : 1) : 1)
            .animation(active ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: on)
            .onAppear { on = true }
    }
}
