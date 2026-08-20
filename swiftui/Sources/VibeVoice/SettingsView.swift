import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle())
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)

            Divider().overlay(Theme.hairline)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {

                    section("Appearance") {
                        AppearancePicker(mode: Binding(
                            get: { state.settings.appearance },
                            set: { state.settings.appearance = $0; $0.applyToApp() }))
                        caption(state.settings.appearance == .system
                                ? "Following macOS — the app flips with your desktop, including on an Auto schedule."
                                : "Pinned to \(state.settings.appearance.label.lowercased()), whatever macOS is set to. Saved with the rest of your settings.")
                    }

                    section("Backdrop") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                                  spacing: 8) {
                            ForEach(Backdrop.allCases) { b in
                                Button {
                                    if b == .custom {
                                        if let path = BackdropPicker.chooseImage() {
                                            state.settings.backdropImagePath = path
                                            state.settings.backdrop = .custom
                                        }
                                    } else {
                                        state.settings.backdrop = b
                                    }
                                } label: {
                                    VStack(spacing: 5) {
                                        ZStack {
                                            if b == .custom {
                                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                    .fill(Theme.fill)
                                                Image(systemName: "photo")
                                                    .font(.system(size: 13))
                                                    .foregroundStyle(Theme.textDim)
                                            } else {
                                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                    .fill(LinearGradient(colors: b.colors,
                                                                         startPoint: .topLeading,
                                                                         endPoint: .bottomTrailing))
                                            }
                                        }
                                        .frame(height: 40)
                                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .stroke(state.settings.backdrop == b
                                                    ? Theme.accent : Theme.hairline,
                                                    lineWidth: state.settings.backdrop == b ? 2 : 1))
                                        Text(b.label)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(state.settings.backdrop == b
                                                             ? Theme.text : Theme.textDim)
                                            .lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        caption(state.settings.backdrop.blurb
                                + (state.settings.backdrop == .custom && !state.settings.backdropImagePath.isEmpty
                                   ? " — " + ((state.settings.backdropImagePath as NSString).lastPathComponent)
                                   : ""))
                        caption("The places are painted rather than photographed, so they stay sharp at any size and add nothing to the app's two megabytes.")
                    }

                    section("Voice") {
                        ChipPicker(options: kVoices, selection: binding(\.voice), columns: 5)
                        caption("marin and cedar are the newest and best.")
                    }

                    section("Model") {
                        ChipPicker(options: kModels, selection: binding(\.model), tint: Theme.voice, columns: 3)
                        caption("Changing the model takes effect on the next connect.")
                    }

                    section("Personality") {
                        TextEditor(text: binding(\.systemPrompt))
                            .font(.system(size: 12.5))
                            .scrollContentBackground(.hidden)
                            .foregroundStyle(Theme.text)
                            .frame(height: 110)
                            .padding(9)
                            .surface(10)
                    }

                    section("Cost mode") {
                        HStack(spacing: 8) {
                            ForEach(QualityMode.allCases, id: \.self) { m in
                                Button {
                                    var s = state.settings
                                    m.apply(to: &s)
                                    state.settings = s
                                    state.applySettingsLive()
                                } label: {
                                    Text(m.label)
                                        .font(.system(size: 12, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 7)
                                        .background(
                                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                .fill(state.settings.qualityMode == m
                                                      ? Theme.accent.opacity(0.9)
                                                      : Theme.fill))
                                        .foregroundStyle(state.settings.qualityMode == m
                                                         ? Theme.onAccent : Theme.text)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        caption(state.settings.qualityMode.blurb)
                        caption("Frames kept in context: \(state.settings.maxScreenFrames). Each one still in context is re-billed on every turn, so a short history is much cheaper than it looks.")
                    }

                    section("Speaking speed") {
                        sliderRow(binding(\.speed), 0.5...1.5, String(format: "%.2f×", state.settings.speed))
                    }

                    section("Screen") {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(state.screenPermission.canCapture ? Theme.good : Theme.bad)
                                .frame(width: 7, height: 7)
                            Text(state.screenPermission.title)
                                .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                            Spacer()
                            Button("Check") { Task { await state.recheckScreenPermission() } }
                                .buttonStyle(GhostButtonStyle())
                        }
                        if state.screenPermission == .needsRestart {
                            Button("Relaunch to apply") { state.relaunchForScreenPermission() }
                                .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                            caption("Permission is granted. macOS only hands it to a process that started after the grant, so one relaunch finishes the job.")
                        } else if state.screenPermission == .denied {
                            Button("Open Privacy Settings") { state.openScreenPrivacySettings() }
                                .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                            caption("Allow Vibe Voice under Privacy & Security › Screen & System Audio Recording. If it is already checked, this build was re-signed since then — toggle it off and back on.")
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Screen Vibe sees")
                                    .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                                Spacer()
                                Button("Rescan") { Task { await state.refreshDisplays() } }
                                    .buttonStyle(GhostButtonStyle())
                            }
                            if state.displays.isEmpty {
                                caption(state.screenPermission.blocksCapture
                                        ? "Displays are listed once Screen Recording is usable."
                                        : "No displays found yet — hit Rescan.")
                            } else {
                                DisplayPicker(displays: state.displays,
                                              active: state.activeDisplay,
                                              followsActive: state.isFollowingActiveDisplay,
                                              onSelect: { state.selectDisplay($0) })
                                caption(state.displays.count == 1
                                        ? "Only one display attached. Plug in another and it appears here — one is shared at a time, and the choice applies to single shots and continuous mode alike."
                                        : "One screen at a time, for single shots and continuous mode alike. Pinning a display keeps it in view even when you move this window to another one; if that display is unplugged, Vibe falls back to the active one instead of failing.")
                            }
                        }

                        HStack {
                            Text("Continuous screen mode")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                            Spacer()
                            NeatToggle(isOn: Binding(
                                get: { state.settings.continuousScreen },
                                set: { state.settings.continuousScreen = $0; state.syncScreenTimer() }))
                        }
                        sliderRow(Binding(
                            get: { state.settings.screenInterval },
                            set: { state.settings.screenInterval = $0 }),
                            2...30,
                            String(format: "every %.0fs", state.settings.screenInterval)) {
                                state.syncScreenTimer()
                            }
                        caption("Frames are filed silently as context, so it won't narrate every one. Ask about your screen whenever you like.")
                    }

                    section("Notion") {
                        SecureTokenField(
                            placeholder: "ntn_… integration token",
                            isSet: Notion.isConfigured,
                            onSave: { try? KeyStore.setSecret($0, forKey: "NOTION_TOKEN") })
                        caption("Create an internal integration at notion.so/my-integrations, then share the pages you want Flow to see with it — it can only read what you share. The token is written to the same 0600 file as your OpenAI key, outside the repo.")
                    }

                    section("Tools") {
                        ForEach(state.tools.specs) { spec in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(spec.summary)
                                            .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                                        if !spec.isReadOnly {
                                            Text("ASKS FIRST")
                                                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                                .tracking(0.6)
                                                .foregroundStyle(Theme.voice)
                                        }
                                    }
                                    Text(spec.name)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Theme.textFaint)
                                }
                                Spacer()
                                NeatToggle(isOn: Binding(
                                    get: { state.tools.isEnabled(spec.name) },
                                    set: { state.setToolEnabled($0, spec.name) }))
                            }
                        }
                        caption("Answered by the app itself in milliseconds, so it replies in the same breath — no Claude Code, no subscription usage. Shortcuts are the extensible part: build one in the Shortcuts app and it becomes something you can ask for out loud.")
                    }

                    section("Dev Mode") {
                        HStack {
                            Text("Let it edit code with Claude Code")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                            Spacer()
                            NeatToggle(isOn: Binding(
                                get: { state.settings.devMode },
                                set: { state.settings.devMode = $0; state.applySettingsLive() }))
                        }
                        TextField("~/dev/vibe-voice", text: Binding(
                            get: { state.settings.devRepo },
                            set: { state.settings.devRepo = $0 }))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .padding(9)
                            .surface(10)
                        caption("Runs claude -p in that folder with --permission-mode acceptEdits, so it writes files without asking. Keep it on a repo you can git checkout.")

                        HStack {
                            Text("Auto-allow everything")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                            Spacer()
                            NeatToggle(isOn: Binding(
                                get: { state.settings.devPermissionMode == "bypassPermissions" },
                                set: { state.settings.devPermissionMode = $0 ? "bypassPermissions" : "acceptEdits" }),
                                tint: Theme.bad)
                        }
                        caption("Off, only file edits are auto-approved — Notion, Slack and shell commands still ask, and since nothing can answer a prompt in the background, the task just stalls. On, nothing asks, which is what makes connectors work by voice. It also means a misheard sentence can run anything.")

                        HStack {
                            Text("Narrate progress out loud")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                            Spacer()
                            NeatToggle(isOn: Binding(
                                get: { state.settings.devNarrate },
                                set: { state.settings.devNarrate = $0 }), tint: Theme.voice)
                        }
                        sliderRow(Binding(
                            get: { state.settings.devNarrateInterval },
                            set: { state.settings.devNarrateInterval = $0 }),
                            10...60,
                            String(format: "every %.0fs", state.settings.devNarrateInterval))
                        caption("Steps are always fed to the model silently, so you can ask \"what are you doing?\" at any point. This only controls whether it volunteers updates — each spoken one costs audio, capped at \(state.settings.devNarrateMax) per task.")
                    }

                    section("Turn detection") {
                        sliderRow(binding(\.vadThreshold), 0.0...1.0,
                                  String(format: "threshold %.2f", state.settings.vadThreshold)) {
                            state.applySettingsLive()
                        }
                        sliderRow(binding(\.silenceDurationMs), 200...1500,
                                  String(format: "silence %.0f ms", state.settings.silenceDurationMs)) {
                            state.applySettingsLive()
                        }
                        HStack {
                            Text("Transcribe my speech")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                            Spacer()
                            NeatToggle(isOn: binding(\.transcribeUser), tint: Theme.voice)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("API key")
                            .font(.system(size: 10.5, weight: .bold)).tracking(1.0)
                            .foregroundStyle(Theme.textFaint)
                        Text(KeyStore.configURL.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textDim)
                            .textSelection(.enabled)
                        Text("Read at runtime. Never stored in the app, never sent anywhere but api.openai.com.")
                            .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    }

                    Button("Apply to live session") { state.applySettingsLive() }
                        .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                        .opacity(state.connection == .live ? 1 : 0.4)
                        .disabled(state.connection != .live)
                }
                .padding(22)
            }
        }
        .frame(width: 440, height: 620)
        .background(Theme.bg)
        // The sheet is its own AppKit window; without this it can render one frame
        // behind the main window after a theme switch.
        .preferredColorScheme(state.settings.appearance.colorScheme)
    }

    private func binding<T>(_ kp: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { state.settings[keyPath: kp] },
                set: { state.settings[keyPath: kp] = $0 })
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .bold)).tracking(1.0)
                .foregroundStyle(Theme.textFaint)
            content()
        }
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
    }

    private func sliderRow(_ b: Binding<Double>, _ r: ClosedRange<Double>, _ label: String,
                           commit: @escaping () -> Void = {}) -> some View {
        HStack(spacing: 14) {
            NeatSlider(value: b, range: r, onCommit: commit)
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textDim)
                .frame(width: 104, alignment: .trailing)
        }
    }
}
