import SwiftUI
import VibeVoiceCore

/// What the app calls itself on screen in Settings.
///
/// Display only, on purpose. The assistant's actual identity lives in the personality
/// prompt (`kDefaultPrompt`, Settings.swift) and in the system prompt sent to the model —
/// neither is touched by this, because a prompt the user has edited must never be
/// rewritten by a label change.
let kAssistantDisplayName = "Flowstate"

/// The name macOS itself shows for this app in System Settings, read from the bundle.
///
/// Kept separate from `kAssistantDisplayName`: the Privacy & Security instructions have to
/// name the row the user is actually hunting for in the system list, which is whatever the
/// bundle is called — telling them to look for a name that isn't there is worse than a
/// slightly inconsistent one.
let kSystemAppName: String =
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
    ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
    ?? "Vantage"

struct SettingsView: View {
    @ObservedObject var state: AppState

    /// Names the chosen photo, or says how many are in the chosen folder.
    private var photoNote: String {
        guard state.settings.backdrop == .custom else { return "" }
        let path = state.settings.backdropImagePath
        guard !path.isEmpty else { return "" }
        let name = (path as NSString).lastPathComponent
        if PhotoBackdrop.isFolder(path) {
            let n = PhotoBackdrop.images(at: path).count
            return n == 0 ? " — no images found in \(name)"
                          : " — \(n) photo\(n == 1 ? "" : "s") in \(name)"
        }
        return " — " + name
    }

    // The title, the close button and the drag handle are the panel's, not this view's —
    // see `FloatingPanel`. Settings only owns what is below the bar.
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {

                    // The order below is the order of the questions people actually
                    // arrive with: who is this, what does it look like, what is behind
                    // it, is it watching my screen, how do I reach it, and only then the
                    // machinery. Personality is first because it is the one setting that
                    // changes what the thing *is*.

                    section("Personality") {
                        HStack {
                            Text("Assistant name")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                            Spacer()
                            Text(kAssistantDisplayName)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.accentInk)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Assistant name")
                        .accessibilityValue(kAssistantDisplayName)

                        caption("\(kAssistantDisplayName) is the name on screen. The instructions "
                                + "below are what it actually is — tone, length, what it does "
                                + "with a screenshot. Edit them freely; they take effect on the "
                                + "next connect, or immediately with Apply to live session.")

                        TextEditor(text: binding(\.systemPrompt))
                            .font(.system(size: 12.5))
                            .scrollContentBackground(.hidden)
                            .foregroundStyle(Theme.text)
                            .frame(height: 110)
                            .padding(9)
                            .surface(10)
                            .accessibilityLabel("Personality instructions for \(kAssistantDisplayName)")
                    }

                    section("Appearance") {
                        AppearancePicker(mode: Binding(
                            get: { state.settings.appearance },
                            set: { state.settings.appearance = $0; $0.applyToApp() }))
                            .accessibilityLabel("Appearance")
                            .accessibilityValue(state.settings.appearance.label)
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
                                        if let path = BackdropPicker.choose() {
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
                                // The selected backdrop is marked only by a stroke colour,
                                // which VoiceOver cannot see. Say it instead.
                                .accessibilityLabel("Backdrop: \(b.label)")
                                .accessibilityAddTraits(state.settings.backdrop == b ? [.isSelected] : [])
                            }
                        }
                        caption(state.settings.backdrop.blurb + photoNote)

                        if state.settings.backdrop == .custom,
                           PhotoBackdrop.isFolder(state.settings.backdropImagePath) {
                            sliderRow(Binding(
                                get: { state.settings.photoRotateSeconds },
                                set: { state.settings.photoRotateSeconds = $0 }),
                                0...600,
                                state.settings.photoRotateSeconds < 1
                                    ? "no rotation"
                                    : String(format: "every %.0fs", state.settings.photoRotateSeconds),
                                accessibilityLabel: "Seconds between photos")
                        }
                        caption("The places are painted rather than photographed, so they stay sharp at any size and add nothing to the app's two megabytes.")

                        if state.settings.backdrop.place != nil {
                            HStack(spacing: 6) {
                                ForEach(["auto"] + Daylight.allCases.map(\.rawValue), id: \.self) { m in
                                    Button {
                                        state.settings.daylightMode = m
                                    } label: {
                                        Text(m == "auto" ? "Auto" : m.prefix(1).uppercased() + m.dropFirst())
                                            .font(.system(size: 11, weight: .medium))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 5)
                                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .fill(state.settings.daylightMode == m
                                                      ? Theme.accent.opacity(0.9) : Theme.fill))
                                            .foregroundStyle(state.settings.daylightMode == m
                                                             ? Theme.onAccent : Theme.text)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Daylight: \(m == "auto" ? "Auto" : m)")
                                    .accessibilityAddTraits(state.settings.daylightMode == m ? [.isSelected] : [])
                                }
                            }
                            caption(state.settings.daylightMode == "auto"
                                    ? "Following your clock — right now it's \(Daylight.now().label.lowercased()). The scene changes as the day does."
                                    : "Pinned to \(state.settings.daylightMode).")

                            HStack {
                                Text("Ambient mode")
                                    .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                                Spacer()
                                NeatToggle(isOn: Binding(
                                    get: { state.settings.ambientMode },
                                    set: { state.settings.ambientMode = $0; state.noteActivity() }))
                                    .accessibilityLabel("Ambient mode")
                            }
                            caption("After 45 seconds of quiet the panels fade out and leave the scene and the orb. The session keeps running — move the mouse to bring it back.")
                        }
                    }

                    // Lifted out of Screen and given its own heading: whether something is
                    // watching your screen every few seconds is not a detail to find by
                    // scrolling past a permission row. The permission and display choice
                    // stay together further down, where they belong.
                    section("Continuous screen mode") {
                        HStack {
                            Text("Continuous screen mode")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                            Spacer()
                            NeatToggle(isOn: Binding(
                                get: { state.settings.continuousScreen },
                                set: { state.settings.continuousScreen = $0; state.syncScreenTimer() }))
                                .accessibilityLabel("Continuous screen mode")
                        }
                        sliderRow(Binding(
                            get: { state.settings.screenInterval },
                            set: { state.settings.screenInterval = $0 }),
                            2...30,
                            String(format: "every %.0fs", state.settings.screenInterval),
                            accessibilityLabel: "Seconds between screen frames") {
                                state.syncScreenTimer()
                            }
                        caption("Frames are filed silently as context, so it won't narrate every one. Ask about your screen whenever you like.")

                        if state.screenPermission.blocksCapture {
                            HStack(spacing: 8) {
                                Circle().fill(Theme.bad).frame(width: 7, height: 7)
                                Text("Screen Recording isn't usable yet — fix it under Screen below.")
                                    .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }

                    section("Anywhere") {
                        HStack {
                            Text("Show in the menu bar")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                            Spacer()
                            NeatToggle(isOn: Binding(
                                get: { state.settings.menuBarEnabled },
                                set: { state.settings.menuBarEnabled = $0 }))
                                .accessibilityLabel("Show in the menu bar")
                        }
                        caption("Connect, send a screenshot or stop a task without finding the window.")

                        HStack(spacing: 6) {
                            ForEach(HotkeyCombo.all) { c in
                                Button {
                                    state.settings.summonHotkey = c.id
                                    state.applySummonHotkey()
                                } label: {
                                    Text(c.label)
                                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(state.settings.summonHotkey == c.id
                                                  ? Theme.accent.opacity(0.9) : Theme.fill))
                                        .foregroundStyle(state.settings.summonHotkey == c.id
                                                         ? Theme.onAccent : Theme.text)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Summon shortcut: \(c.label)")
                                .accessibilityAddTraits(state.settings.summonHotkey == c.id ? [.isSelected] : [])
                            }
                            Button {
                                state.settings.summonHotkey = ""
                                state.applySummonHotkey()
                            } label: {
                                Text("Off")
                                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(state.settings.summonHotkey.isEmpty
                                              ? Theme.accent.opacity(0.9) : Theme.fill))
                                    .foregroundStyle(state.settings.summonHotkey.isEmpty
                                                     ? Theme.onAccent : Theme.text)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Summon shortcut: off")
                            .accessibilityAddTraits(state.settings.summonHotkey.isEmpty ? [.isSelected] : [])
                        }
                        caption("Summons \(kAssistantDisplayName) from any app, and hides it again if it is already in front. ⌘⇧2 still sends a screenshot from anywhere. If a shortcut does nothing, another app already owns it — pick a different one.")
                    }

                    section("Dev Mode") {
                        // Every switch below can change files on this Mac. The block leads
                        // with what the whole thing is, and no individual switch is left as
                        // a bare label — each says in one line what turning it on does.
                        caption("Hands spoken coding tasks to Claude Code running on this Mac, "
                                + "under your own Claude account — \(kAssistantDisplayName) never "
                                + "sees your Anthropic credentials. Off, nothing here can touch a file.")

                        devToggle("Let it edit code with Claude Code",
                                  "The master switch. Runs `claude -p` in the folder below and lets it "
                                  + "write files without asking, so keep it on a repo you can `git checkout`.",
                                  isOn: Binding(
                                    get: { state.settings.devMode && state.claudeAvailability == .ready },
                                    set: { state.settings.devMode = $0; state.applySettingsLive() }),
                                  enabled: state.claudeAvailability == .ready)

                        // Offering a switch that cannot work is worse than not offering it:
                        // every task would fail with something that reads like a bug.
                        if state.claudeAvailability != .ready {
                            HStack(spacing: 7) {
                                Circle().fill(Theme.bad).frame(width: 6, height: 6)
                                Text(state.claudeAvailability.headline)
                                    .font(.system(size: 12)).foregroundStyle(Theme.text)
                                Spacer()
                                Button("Check again") { state.refreshClaudeAvailability() }
                                    .buttonStyle(GhostButtonStyle())
                                    .accessibilityLabel("Check for Claude Code again")
                            }
                            Text(state.claudeAvailability.detail)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.textFaint)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Repository it works in")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                            TextField("~/dev/vibe-voice", text: Binding(
                                get: { state.settings.devRepo },
                                set: { state.settings.devRepo = $0 }))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.text)
                                .padding(9)
                                .surface(10)
                                .accessibilityLabel("Repository Dev Mode works in")
                            Text("Every task runs here, and nowhere else.")
                                .font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                        }

                        devToggle("Commit each task when it finishes",
                                  "Only what the task itself changed is committed — anything you already "
                                  + "had in progress is left alone, because the restore point taken "
                                  + "beforehand is what it diffs against. Commits land on your current "
                                  + "branch, and each task also gets a vantage/T1-… ref to review or "
                                  + "revert. Failed or permission-blocked tasks are never committed.",
                                  isOn: Binding(
                                    get: { state.settings.devAutoCommit },
                                    set: { state.settings.devAutoCommit = $0 }))

                        devToggle("…and push it to the remote",
                                  "The only way the work reaches a Claude Code running in the cloud, "
                                  + "which can see the remote and nothing else. Needs the switch above.",
                                  isOn: Binding(
                                    get: { state.settings.devAutoPush && state.settings.devAutoCommit },
                                    set: { state.settings.devAutoPush = $0 }),
                                  enabled: state.settings.devAutoCommit)

                        devToggle("Auto-allow everything",
                                  "Off, only file edits are auto-approved — Notion, Slack and shell "
                                  + "commands still ask, and since nothing can answer a prompt in the "
                                  + "background, the task just stalls. On, nothing asks, which is what "
                                  + "makes connectors work by voice. It also means a misheard sentence "
                                  + "can run anything.",
                                  isOn: Binding(
                                    get: { state.settings.devPermissionMode == "bypassPermissions" },
                                    set: { state.settings.devPermissionMode = $0 ? "bypassPermissions" : "acceptEdits" }),
                                  tint: Theme.bad)

                        devToggle("Narrate progress out loud",
                                  "Steps are always fed to the model silently, so you can ask \"what are "
                                  + "you doing?\" at any point. This only controls whether it volunteers "
                                  + "updates — each spoken one costs audio, capped at "
                                  + "\(state.settings.devNarrateMax) per task.",
                                  isOn: Binding(
                                    get: { state.settings.devNarrate },
                                    set: { state.settings.devNarrate = $0 }),
                                  tint: Theme.voice)
                        sliderRow(Binding(
                            get: { state.settings.devNarrateInterval },
                            set: { state.settings.devNarrateInterval = $0 }),
                            10...60,
                            String(format: "every %.0fs", state.settings.devNarrateInterval),
                            accessibilityLabel: "Seconds between spoken updates")
                    }

                    section("Voice") {
                        ChipPicker(options: kVoices, selection: binding(\.voice), columns: 5)
                        caption("marin and cedar are the newest and best.")
                    }

                    section("Model") {
                        ChipPicker(options: kModels, selection: binding(\.model), tint: Theme.voice, columns: 3)
                        caption("Changing the model takes effect on the next connect.")
                    }

                    section("Cost mode") {
                        HStack(spacing: 8) {
                            ForEach(QualityMode.allCases, id: \.self) { m in
                                Button {
                                    state.setQualityMode(m)
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
                                .accessibilityLabel("Cost mode: \(m.label)")
                                .accessibilityAddTraits(state.settings.qualityMode == m ? [.isSelected] : [])
                            }
                        }
                        caption(state.settings.qualityMode.blurb)
                        caption("Frames kept in context: \(state.settings.maxScreenFrames). Each one still in context is re-billed on every turn, so a short history is much cheaper than it looks.")
                    }

                    section("Speaking speed") {
                        sliderRow(binding(\.speed), 0.5...1.5, String(format: "%.2f×", state.settings.speed),
                                  accessibilityLabel: "Speaking speed")
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
                                .accessibilityLabel("Check screen recording permission")
                        }
                        if state.screenPermission == .needsRestart {
                            Button("Relaunch to apply") { state.relaunchForScreenPermission() }
                                .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                            caption("Permission is granted. macOS only hands it to a process that started after the grant, so one relaunch finishes the job.")
                        } else if state.screenPermission == .denied {
                            Button("Open Privacy Settings") { state.openScreenPrivacySettings() }
                                .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                            caption("Allow \(kSystemAppName) under Privacy & Security › Screen & System Audio Recording — that is the name macOS lists this app under. If it is already checked, this build was re-signed since then — toggle it off and back on.")
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Screen \(kAssistantDisplayName) sees")
                                    .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                                Spacer()
                                Button("Rescan") { Task { await state.refreshDisplays() } }
                                    .buttonStyle(GhostButtonStyle())
                                    .accessibilityLabel("Rescan displays")
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
                                        : "One screen at a time, for single shots and continuous mode alike. Pinning a display keeps it in view even when you move this window to another one; if that display is unplugged, \(kAssistantDisplayName) falls back to the active one instead of failing.")
                            }
                        }

                        caption("Continuous screen mode and how often it looks are near the top of this window.")
                    }

                    section("Notion") {
                        SecureTokenField(
                            placeholder: "ntn_… integration token",
                            isSet: Notion.isConfigured,
                            onSave: { try? KeyStore.setSecret($0, forKey: "NOTION_TOKEN") })
                        caption("Create an internal integration at notion.so/my-integrations, then share the pages you want \(kAssistantDisplayName) to see with it — it can only read what you share. The token is written to the same 0600 file as your OpenAI key, outside the repo.")
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
                                    .accessibilityLabel(spec.summary)
                            }
                        }
                        caption("Answered by the app itself in milliseconds, so it replies in the same breath — no Claude Code, no subscription usage. Shortcuts are the extensible part: build one in the Shortcuts app and it becomes something you can ask for out loud.")
                    }

                    section("Turn detection") {
                        sliderRow(binding(\.vadThreshold), 0.0...1.0,
                                  String(format: "threshold %.2f", state.settings.vadThreshold),
                                  accessibilityLabel: "Voice detection threshold") {
                            state.applySettingsLive()
                        }
                        sliderRow(binding(\.silenceDurationMs), 200...1500,
                                  String(format: "silence %.0f ms", state.settings.silenceDurationMs),
                                  accessibilityLabel: "Silence before a turn ends, in milliseconds") {
                            state.applySettingsLive()
                        }
                        HStack {
                            Text("Transcribe my speech")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                            Spacer()
                            NeatToggle(isOn: binding(\.transcribeUser), tint: Theme.voice)
                                .accessibilityLabel("Transcribe my speech")
                        }
                    }

                    section("Conversations") {
                        caption("Each conversation is saved on its own — its transcript, "
                                + "its summaries, its own name in the switcher at the top "
                                + "of the sidebar. Nothing here deletes anything; it only "
                                + "decides which one is in front of you when \(kAssistantDisplayName) opens.")

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Pick up where I left off")
                                    .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                                Text(state.settings.resumeLastSession
                                     ? "Launching reopens the last conversation, with its history."
                                     : "Launching starts a new conversation. The last one stays in the switcher.")
                                    .font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                            }
                            Spacer()
                            NeatToggle(isOn: binding(\.resumeLastSession), tint: Theme.voice)
                                .accessibilityLabel("Pick up where I left off")
                        }

                        HStack(spacing: 10) {
                            Button("New conversation") { state.newConversation() }
                                .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                            // Reads this conversation's file again and folds back anything
                            // missing. Costs nothing when nothing is missing.
                            Button("Reload transcript") { state.refreshTranscript() }
                                .buttonStyle(GhostButtonStyle(tint: Theme.voiceInk))
                            Text(savedConversationsLine)
                                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                        }

                        if let problem = state.conversation.lastReadError {
                            caption("Last read back: " + problem)
                        }
                        // Should be zero. It counts lines that were put on screen waiting
                        // for their text and never got it — so when it is not zero, the
                        // number is the only evidence that happened.
                        if state.abandonedTranscriptUpdates > 0 {
                            caption("\(state.abandonedTranscriptUpdates) line(s) never came "
                                    + "back transcribed this session.")
                        }
                    }

                    section("Memory & privacy") {
                        caption("What \(kAssistantDisplayName) keeps of a conversation. The transcript on "
                                + "screen always shows what was said — these control what "
                                + "survives it.")

                        privacyToggle("Keep a transcript of what I say", \.privacy.captureUserSpeech)
                        privacyToggle("Keep a transcript of my replies", \.privacy.captureAssistantSpeech)
                        privacyToggle("Keep how long and how loud each utterance was",
                                      \.privacy.captureAudioMetadata)
                        privacyToggle("Redact keys, emails and long numbers",
                                      \.privacy.redactSensitiveText)
                        privacyToggle("Save to disk", \.privacy.persistToDisk)

                        sliderRow(Binding(
                            get: { state.settings.privacy.retentionHours },
                            set: { state.settings.privacy.retentionHours = $0 } ),
                            0...(24 * 30),
                            state.settings.privacy.retentionHours > 0
                                ? "keep \(TranscriptPrivacy.humanHours(state.settings.privacy.retentionHours))"
                                : "keep forever",
                            accessibilityLabel: "How long transcripts are kept") {
                            state.applyPrivacySettings()
                        }
                        caption("Turning this down deletes what is already past the window, "
                                + "not just what comes next.")

                        // The audio opt-in, kept visibly separate from everything above
                        // it: this is the only switch here that would put a recording of
                        // a room on disk.
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keep audio clips")
                                    .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                                Text("Not implemented yet — see AudioClipRecorder.")
                                    .font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                            }
                            Spacer()
                            NeatToggle(isOn: privacyBinding(\.privacy.keepAudioClips), tint: Theme.voice)
                                .accessibilityLabel("Keep audio clips")
                        }

                        HStack {
                            Text("Pause recording")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                            Spacer()
                            NeatToggle(isOn: privacyBinding(\.privacy.paused), tint: Theme.voice)
                                .accessibilityLabel("Pause recording")
                        }
                        caption(state.conversation.privacy.summaryLine
                                + " \(state.conversation.entryCount) line(s) held, "
                                + "\(state.conversation.bytesOnDisk / 1024) KB on disk.")

                        Text(ConversationStore.conversationsDirectory.path)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.textDim)
                            .textSelection(.enabled)

                        HStack(spacing: 10) {
                            Button("Forget this conversation") {
                                _ = state.forgetThisConversation()
                            }
                            .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                            Button("Delete everything") {
                                state.conversation.forgetEverything()
                            }
                            .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                        }
                    }

                    section("Summaries") {
                        HStack {
                            Text("Summarise as we go")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                            Spacer()
                            NeatToggle(isOn: privacyBinding(\.summaries.enabled), tint: Theme.voice)
                                .accessibilityLabel("Summarise as we go")
                        }
                        sliderRow(Binding(
                            get: { state.settings.summaries.everySeconds },
                            set: { state.settings.summaries.everySeconds = $0 } ),
                            60...1800,
                            String(format: "every %.0f min", state.settings.summaries.everySeconds / 60),
                            accessibilityLabel: "Minutes between summaries") {
                            state.applyPrivacySettings()
                        }
                        caption("Or sooner, once \(state.settings.summaries.everyNEntries) turns "
                                + "have piled up. Summaries are written locally and filed back "
                                + "into the conversation silently, so I can refer to what was "
                                + "said earlier without the whole history staying on the wire.")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("API key")
                            .font(.system(size: 10.5, weight: .bold)).tracking(1.0)
                            .foregroundStyle(Theme.textFaint)
                            .accessibilityAddTraits(.isHeader)
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
        // Width only. The height is the panel's business now: it floats inside the app
        // window, so it has to be allowed to shrink when the window is short rather than
        // hang off the bottom edge.
        .frame(maxWidth: 440)
    }

    private var savedConversationsLine: String {
        let n = state.sessions.count
        guard n > 0 else { return "Nothing saved yet." }
        return "\(n) saved" + (state.settings.privacy.persistToDisk
                               ? "." : " — but \"Save to disk\" is off, so they go when \(kAssistantDisplayName) quits.")
    }

    private func binding<T>(_ kp: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { state.settings[keyPath: kp] },
                set: { state.settings[keyPath: kp] = $0 })
    }

    /// Like `binding`, but tells AppState afterwards. Privacy settings are not merely
    /// stored — turning retention down deletes, turning persistence off wipes the files —
    /// so they have to be pushed through rather than read at some later moment.
    private func privacyBinding(_ kp: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { state.settings[keyPath: kp] },
                set: {
                    state.settings[keyPath: kp] = $0
                    state.applyPrivacySettings()
                })
    }

    private func privacyToggle(_ label: String, _ kp: WritableKeyPath<AppSettings, Bool>) -> some View {
        HStack {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.text)
            Spacer()
            NeatToggle(isOn: privacyBinding(kp), tint: Theme.voice)
                .accessibilityLabel(label)
        }
    }

    /// One switch in the Dev Mode block: what it does on the left, the switch on the
    /// right, and a plain sentence underneath. Nothing in Dev Mode gets a bare label —
    /// each of these can change files on this Mac, so each says so.
    private func devToggle(_ title: String,
                           _ detail: String,
                           isOn: Binding<Bool>,
                           tint: Color = Theme.accent,
                           enabled: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top) {
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(enabled ? Theme.text : Theme.textDim)
                Spacer()
                NeatToggle(isOn: isOn, tint: tint)
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.4)
                    .accessibilityLabel(title)
                    .accessibilityHint(detail)
            }
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .bold)).tracking(1.0)
                .foregroundStyle(Theme.textFaint)
                // Uppercased for the eye; VoiceOver should read the real words, and read
                // them as the heading they are.
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
    }

    private func sliderRow(_ b: Binding<Double>, _ r: ClosedRange<Double>, _ label: String,
                           accessibilityLabel: String? = nil,
                           commit: @escaping () -> Void = {}) -> some View {
        HStack(spacing: 14) {
            NeatSlider(value: b, range: r, onCommit: commit)
                .accessibilityLabel(accessibilityLabel ?? label)
                .accessibilityValue(label)
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textDim)
                .frame(width: 104, alignment: .trailing)
        }
    }
}
