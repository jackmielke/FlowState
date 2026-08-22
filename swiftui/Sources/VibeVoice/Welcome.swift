import SwiftUI
import VibeVoiceCore

/// First run.
///
/// Two things stand between someone opening FlowState and talking to it: an OpenAI key,
/// and — only if they want Dev Mode — their own Claude Code. Everything here exists so a
/// friend who was handed this app never has to be told what to edit in which file.
///
/// The key is VERIFIED, not just stored. Accepting a typo and failing later at Connect
/// with a socket error is the difference between "it doesn't work" and "that key was
/// rejected, here's why".
struct WelcomeView: View {
    @ObservedObject var state: AppState
    var onDone: () -> Void

    @State private var key = ""
    @State private var checking = false
    @State private var problem: String?
    @State private var keyOK = KeyStore.secret(forKey: "OPENAI_API_KEY") != nil
    @State private var claude = ClaudeCode.availability()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("FLOW")
                    .font(.system(size: 12, weight: .bold, design: .rounded)).tracking(2.4)
                    .foregroundStyle(Theme.accentInk)
                Text("A voice you can talk to, that can see your screen.")
                    .font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Two minutes of setup, then you just talk.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 26).padding(.top, 26).padding(.bottom, 20)

            Divider().overlay(Theme.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    step(1, "Your OpenAI key", done: keyOK) {
                        Text("FlowState talks to OpenAI's realtime model. The key stays on this Mac, in a file only you can read, and goes nowhere except api.openai.com.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)

                        Link("Create a key at platform.openai.com",
                             destination: URL(string: "https://platform.openai.com/api-keys")!)
                            .font(.system(size: 12))

                        if keyOK {
                            HStack(spacing: 7) {
                                Circle().fill(Theme.good).frame(width: 6, height: 6)
                                Text("Key saved and verified")
                                    .font(.system(size: 12)).foregroundStyle(Theme.text)
                                Spacer()
                                Button("Replace") { keyOK = false; key = "" }
                                    .buttonStyle(GhostButtonStyle())
                            }
                        } else {
                            HStack(spacing: 8) {
                                SecureField("sk-proj-…", text: $key)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.text)
                                    .padding(9).surface(10)
                                Button(checking ? "Checking…" : "Verify & save") { verify() }
                                    .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                                    .disabled(checking || key.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            if let problem {
                                Text(problem)
                                    .font(.system(size: 11.5)).foregroundStyle(Theme.badInk)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("You'll need a little credit on the account — realtime voice is roughly five to fifteen cents a minute, and Budget mode in Settings cuts that to about a third.")
                                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    step(2, "Your Claude Code — optional", done: claude == .ready) {
                        Text("Dev Mode lets you say \"add a dark mode toggle\" and have it actually happen in your own repo. It runs Claude Code on YOUR machine under YOUR account — FlowState never sees your Anthropic credentials.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 7) {
                            Circle().fill(claude == .ready ? Theme.good : Theme.textFaint)
                                .frame(width: 6, height: 6)
                            Text(claude.headline)
                                .font(.system(size: 12)).foregroundStyle(Theme.text)
                            Spacer()
                            Button("Check again") { claude = ClaudeCode.availability() }
                                .buttonStyle(GhostButtonStyle())
                        }
                        Text(claude.detail)
                            .font(.system(size: 11.5, design: claude == .ready ? .default : .monospaced))
                            .foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    step(3, "Permissions, when you need them", done: false) {
                        Text("The microphone is asked for on Connect. Screen access is only needed if you want it to look at your screen — macOS has no Allow button for that one, so FlowState adds itself to the list and you switch it on in System Settings.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(26)
            }

            Divider().overlay(Theme.hairline)

            HStack {
                Text(keyOK ? "You're set." : "A key is needed before you can connect.")
                    .font(.system(size: 12)).foregroundStyle(keyOK ? Theme.text : Theme.textDim)
                Spacer()
                Button(keyOK ? "Start talking" : "Skip for now") { onDone() }
                    .buttonStyle(GhostButtonStyle(tint: keyOK ? Theme.accentInk : Theme.textDim))
            }
            .padding(.horizontal, 26).padding(.vertical, 16)
        }
        .frame(width: 560, height: 620)
        .background(Theme.bg)
    }

    // MARK: -

    @ViewBuilder
    private func step(_ n: Int, _ title: String, done: Bool,
                      @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(done ? Theme.good.opacity(0.9) : Theme.fill)
                        .frame(width: 19, height: 19)
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                    } else {
                        Text("\(n)").font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textDim)
                    }
                }
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text)
            }
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(.leading, 28)
        }
    }

    /// Proves the key works before storing it, by minting a real ephemeral token — the
    /// exact call Connect makes. A key that passes here cannot fail there for its own sake.
    private func verify() {
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        checking = true
        problem = nil
        Task { @MainActor in
            defer { checking = false }
            do {
                _ = try await EphemeralToken.mint(apiKey: candidate, model: state.settings.model)
                try KeyStore.setSecret(candidate, forKey: "OPENAI_API_KEY")
                key = ""
                keyOK = true
            } catch {
                problem = Self.explain(error)
            }
        }
    }

    /// Turns the two failures people actually hit into sentences worth reading.
    private static func explain(_ error: Error) -> String {
        let m = error.localizedDescription
        let l = m.lowercased()
        if l.contains("401") || l.contains("invalid") || l.contains("incorrect api key") {
            return "OpenAI rejected that key. Check it was copied whole — they start with sk- and are long."
        }
        if let a = BannerAction.forAPIError(m), a == .addCredits {
            return "The key works, but the account has no credit. Add some at platform.openai.com and try again."
        }
        return m
    }
}
