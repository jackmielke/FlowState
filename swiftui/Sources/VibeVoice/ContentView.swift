import SwiftUI
import AppKit

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
            VisualEffectBackground()
            LinearGradient(colors: [Theme.bg.opacity(0.94), Theme.bg.opacity(0.99)],
                           startPoint: .top, endPoint: .bottom)
            // faint accent wash from the top-left, so the flat field — near-black or
            // paper, depending on the theme — never reads as dead
            RadialGradient(colors: [accentForMode.opacity(0.10), .clear],
                           center: .init(x: 0.28, y: 0.18), startRadius: 0, endRadius: 620)
                .animation(.easeInOut(duration: 0.6), value: mode)

            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.hairline)
                HStack(spacing: 0) {
                    stage
                    Divider().overlay(Theme.hairline)
                    sidebar
                }
            }
            WindowConfigurator(appearance: state.settings.appearance).frame(width: 0, height: 0)
        }
        .frame(minWidth: 940, minHeight: 620)
        .preferredColorScheme(state.settings.appearance.colorScheme)
        .onAppear { state.settings.appearance.applyToApp() }
        .sheet(isPresented: $state.showSettings) { SettingsView(state: state) }
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
                    Text("VIBE VOICE")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .tracking(2.0)
                        .foregroundStyle(Theme.text.opacity(0.92))
                }

                statusPill

                if state.isWatching { watchingPill }

                if state.devTaskRunning { codingPill }

                Spacer()

                if let n = state.lastCaptureNote {
                    Text("last frame \(n)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textFaint)
                }

                costReadout

                Button { Task { await state.captureAndSend(auto: false) } } label: {
                    Image(systemName: "rectangle.dashed.badge.record")
                }
                .buttonStyle(IconButtonStyle())
                .help("Send a screenshot (⌘⇧2)")

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
            Text("WATCHING · \(Int(state.settings.screenInterval))s")
                .font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(0.8)
        }
        .foregroundStyle(Theme.onAccent)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Theme.accent.opacity(0.92)))
        .modifier(PulseIf(active: true))
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
        """
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
            if state.screenPermissionDenied { screenPermissionCard }
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
            }
            .padding(.top, 6)

            LevelMeter(history: state.audio.micHistory, tint: mode == .speaking ? Theme.voice : Theme.accent)
                .padding(.top, 20)
                .opacity(state.audio.running ? 1 : 0.32)

            Spacer(minLength: 20)

            HStack(spacing: 10) {
                Button(connectLabel) { state.toggleConnection() }
                    .buttonStyle(PrimaryButtonStyle(tint: state.connection == .live ? Theme.bad : Theme.accent))

                Button {
                    Task { await state.captureAndSend(auto: false) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.viewfinder").font(.system(size: 11.5))
                        Text("Show screen")
                        Text("⌘⇧2").foregroundStyle(Theme.textFaint)
                    }
                }
                .buttonStyle(GhostButtonStyle())

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
        case .error: return "Something broke"
        case .live:
            if mode == .speaking { return "Vibe is speaking" }
            if state.userSpeaking { return "Listening…" }
            return "Just talk"
        }
    }

    private var subhead: String {
        switch state.connection {
        case .idle: return "Voice-first. Server VAD handles turn-taking — no push-to-talk."
        case .connecting: return "Minting an ephemeral token and opening the socket."
        case .error: return "The exact API message is above."
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
            Button { state.banner = nil } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain).foregroundStyle(Theme.textFaint)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.bad.opacity(0.10))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.bad.opacity(0.30), lineWidth: 1)))
        .padding(.top, 14)
    }

    private var screenPermissionCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Screen Recording is off")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
            Text("macOS needs you to allow Vibe Voice under Privacy & Security › Screen & System Audio Recording. Toggle it on, then relaunch the app.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings") { ScreenCapture.openPrivacySettings() }
                .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
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
                        Text("Your words and Vibe's replies land here\nas you talk.")
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
