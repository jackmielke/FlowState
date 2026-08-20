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

                    section("Speaking speed") {
                        sliderRow(binding(\.speed), 0.5...1.5, String(format: "%.2f×", state.settings.speed))
                    }

                    section("Screen") {
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
                        .buttonStyle(GhostButtonStyle(tint: Theme.accent))
                        .opacity(state.connection == .live ? 1 : 0.4)
                        .disabled(state.connection != .live)
                }
                .padding(22)
            }
        }
        .frame(width: 440, height: 620)
        .background(Theme.bg)
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
