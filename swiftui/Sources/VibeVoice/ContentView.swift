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
            if state.audio.outLevel > 0.004 { return .speaking }
            if state.userSpeaking || state.audio.micLevel > 0.012 { return .listening }
            return .idle
        }
    }

    private var orbLevel: Float { max(state.audio.micLevel, state.audio.outLevel * 1.15) }

    /// The painted scenes are all dusk-to-night rooms. Light chrome on top of one is not
    /// a style choice, it is unreadable — so a scene pins the UI dark regardless of the
    /// light/dark setting, which goes back to governing Midnight and Paper.
    private var sceneIsDark: Bool { state.settings.backdrop.place != nil }

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
            && state.settings.backdrop.place != nil
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
                             rotationIndex: photoIndex)
                // Keep the mode tint, so the room still shifts colour when Vantage speaks.
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
        .onAppear { state.applyEffectiveAppearance() }
        .onChange(of: state.settings.backdrop) { _, _ in state.applyEffectiveAppearance() }
        .onChange(of: state.settings.appearance) { _, _ in state.applyEffectiveAppearance() }
        .sheet(isPresented: $state.showSettings) { SettingsView(state: state) }
        .sheet(isPresented: $state.showWelcome) {
            WelcomeView(state: state) { state.showWelcome = false }
        }
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
                    Text("VANTAGE")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .tracking(2.0)
                        .foregroundStyle(Theme.text.opacity(0.92))
                }

                statusPill

                if state.isWatching { watchingPill }

                if state.devTaskRunning { codingPill }

                if responseLabel != nil { responsePill }

                Spacer()

                if let n = state.lastCaptureNote {
                    Text("last frame \(n)\(lastCaptureFrom)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textFaint)
                }

                costReadout

                if state.isResponding || state.isCancellingResponse {
                    Button { state.stopResponse() } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help(state.isCancellingResponse
                          ? "Still stopping — click again to force the session back to idle"
                          : "Stop this reply")
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

    /// Which screen the last frame came from — worth the header width only once there is
    /// more than one it could have been.
    private var lastCaptureFrom: String {
        guard state.displays.count > 1, let name = state.lastCaptureDisplay else { return "" }
        return " · \(name)"
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
            return "Send a screenshot (⌘⇧2). Vantage is mid-reply, so the frame is filed now and answered next."
        }
        return "Send a screenshot (⌘⇧2)"
    }

    /// Claude Code runs for minutes with the voice loop idle, so this is the only
    /// on-screen proof that something is still happening.
    private var codingPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "curlybraces").font(.system(size: 8.5))
            Text("CODING")
                .font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(0.8)
        }
        .foregroundStyle(Theme.onDev)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Theme.dev))
        .modifier(PulseIf(active: true))
        .help(state.devTaskSummary ?? "Claude Code is working")
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

                if case .error = state.connection, let a = state.bannerAction {
                    Button(a.label) { NSWorkspace.shared.open(a.url) }
                        .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                        .padding(.top, 2)
                }
            }
            .padding(.top, 6)

            LevelMeter(history: state.audio.micHistory, tint: mode == .speaking ? Theme.voice : Theme.accent)
                .padding(.top, 20)
                .opacity(state.audio.running ? 1 : 0.32)

            Spacer(minLength: 20)

            HStack(spacing: 10) {
                Button(connectLabel) { state.toggleConnection() }
                    .buttonStyle(PrimaryButtonStyle(tint: state.connection == .live ? Theme.bad : Theme.accent))

                // Gated, not blocked. While a reply is streaming the frame is still worth
                // filing — it is answered on the next turn — but a SECOND press would
                // only be coalesced into the same queued turn, so the button says
                // "Queued" and stops taking clicks until that turn goes out.
                Button {
                    Task { await state.captureAndSend(auto: false) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: state.hasQueuedResponse ? "clock" : "camera.viewfinder")
                            .font(.system(size: 11.5))
                        Text(state.hasQueuedResponse ? "Queued" : "Show screen")
                        if !state.hasQueuedResponse {
                            Text("⌘⇧2").foregroundStyle(Theme.textFaint)
                        }
                    }
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(state.hasQueuedResponse)
                .opacity(state.hasQueuedResponse ? 0.5 : 1)
                .help(captureHelp)

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

            // Its own line rather than a fifth button: at the 940pt minimum width the
            // action row is already full, and this is a statement of what is being shared
            // more than it is an action — so it reads better directly under the controls
            // it qualifies.
            if !state.displays.isEmpty {
                ScreenPicker(displays: state.displays,
                             active: state.activeDisplay,
                             followsActive: state.isFollowingActiveDisplay,
                             onSelect: { state.selectDisplay($0) })
                    .padding(.top, 10)
            }

            Text(state.audio.running ? state.audio.formatDescription : "audio idle · nothing is captured until you connect")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textFaint.opacity(0.8))
                .padding(.top, 14)

            Spacer(minLength: 14)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if mode == .speaking { return "Vantage is speaking" }
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

    /// Two genuinely different problems, so two genuinely different cards.
    /// Telling a user who has already granted the permission that it is "off" is
    /// the bug this exists to avoid.
    private var screenPermissionCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(state.screenPermission.title)
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)

            if state.screenPermission == .needsRestart {
                Text("You've allowed it — macOS just won't hand the permission to an app that was already running when you granted it. Relaunch Vantage and screen capture works immediately. Nothing else to change.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Relaunch Vantage") { state.relaunchForScreenPermission() }
                        .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                    Button("Check again") { Task { await state.recheckScreenPermission() } }
                        .buttonStyle(GhostButtonStyle())
                }
            } else {
                Text("Allow Vantage under Privacy & Security › Screen & System Audio Recording, then come back — the app re-checks every time you switch to it, and will tell you if a relaunch is needed.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Already checked in that list? This build was re-signed since you granted it, so macOS sees a different app. Toggle Vibe Voice off and back on, or run:  tccutil reset ScreenCapture com.jackmielke.vibevoice")
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

            HStack(spacing: 7) {
                Text("TRANSCRIPT")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(1.4)
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                Text("\(state.transcript.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textFaint.opacity(0.7))
            }
            .padding(.horizontal, 18).padding(.top, 15).padding(.bottom, 9)

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
                        Text("Your words and Vantage's replies land here\nas you talk.")
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
