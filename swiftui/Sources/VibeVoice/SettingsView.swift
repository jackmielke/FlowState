import SwiftUI
import VibeVoiceCore

/// What the app calls itself on screen in Settings.
///
/// Display only, on purpose. The assistant's actual identity lives in the personality
/// prompt (`kDefaultPrompt`, Settings.swift) and in the system prompt sent to the model —
/// neither is touched by this, because a prompt the user has edited must never be
/// rewritten by a label change.
let kAssistantDisplayName = "FlowState"

/// The name macOS itself shows for this app in System Settings, read from the bundle.
///
/// Kept separate from `kAssistantDisplayName`: the Privacy & Security instructions have to
/// name the row the user is actually hunting for in the system list, which is whatever the
/// bundle is called — telling them to look for a name that isn't there is worse than a
/// slightly inconsistent one.
let kSystemAppName: String =
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
    ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
    ?? "FlowState"

struct SettingsView: View {
    @ObservedObject var state: AppState

    /// Lays the open tab out in a plain stack instead of a scroll view.
    ///
    /// Only `SettingsSnapshot` passes this. `ImageRenderer` walks the view tree with no
    /// window behind it, and a `ScrollView` in that situation lays its content against an
    /// unspecified proposal and renders as an empty rectangle — which makes an offscreen
    /// snapshot a picture of the chrome and nothing else. Flattened, the same content
    /// measures and draws exactly as it does on screen.
    var flattened = false

    /// Why the last video loop could not be installed, if it could not. Kept here rather
    /// than in settings: it describes one click, not a preference.
    @State private var motionInstallError: String?

    /// Which tab is open, remembered between launches.
    ///
    /// In `UserDefaults` rather than in `AppSettings`: which pane of Settings you happened
    /// to leave open is not a preference worth versioning, migrating or writing to the
    /// settings file people hand-edit. Stored as a raw string and read back through
    /// `SettingsTab(stored:)`, which falls back rather than trapping on a tab this build
    /// no longer has.
    @AppStorage("settings.tab") private var storedTab: String = SettingsTab.general.rawValue
    @State private var hoveredTab: SettingsTab?
    @Namespace private var tabPill

    private var tab: SettingsTab { SettingsTab(stored: storedTab) }

    /// The recording the result card at the top of Recordings is about: the one this
    /// session produced, or failing that the newest on disk, so the card is there after
    /// a relaunch too.
    private var latestRecording: SessionRecorder.Recording? {
        state.lastRecording ?? state.recordings.first
    }

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

    /// The line under the Still backdrops grid.
    ///
    /// It describes the chosen still backdrop when one is chosen. When a moving background
    /// is up, no tile in this grid is ringed, and a caption still describing whichever
    /// still backdrop was selected last would be describing something that is not on
    /// screen — so it says that instead, and points at the section that is.
    private var stillNote: String {
        guard state.settings.backdrop != .motion else {
            return "None of these is showing — \(state.settings.motionStyle.label), below, is. Pick one here to go back to a still backdrop."
        }
        return state.settings.backdrop.blurb + photoNote
    }


    // The title, the close button and the drag handle are the panel's, not this view's —
    // see `FloatingPanel`. Settings owns the tab strip and everything below it.
    //
    // Tabs rather than one long scroll, and the pane resizes to whichever one is open:
    // that is how a macOS preferences window has behaved since the beginning, and it is
    // the only arrangement where a two-line tab is two lines tall instead of a short
    // paragraph stranded in a 620-point window. `measuresPanelContent` is what reports
    // the height up; `FloatingPanel` animates to it.
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                tabStrip
                Divider().overlay(Theme.hairline)
            }
            // Measured rather than declared: the strip's height follows its icon and label
            // fonts, and a constant standing in for it is wrong the day either changes.
            .measuresPanelContent()

            if flattened {
                pageBody
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    pageBody
                }
                // Without this a tab whose content fits still rubber-bands when you
                // scroll it, which reads as the pane being loose.
                .scrollBounceBehavior(.basedOnSize)
                // A fresh scroll view per tab, so switching tabs starts at the top
                // instead of halfway down someone else's content.
                .id(tab)
                .transition(.opacity)
            }
        }
        // Width only. The height is the panel's business: it floats inside the app window,
        // so it has to be free to shrink when the window is short.
        .frame(maxWidth: 440)
    }

    private var pageBody: some View {
        VStack(alignment: .leading, spacing: 26) {
            tabContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .measuresPanelContent()
    }

    // MARK: - Tabs

    /// A row of icon-and-label tabs, with the selection as a moving pill.
    ///
    /// Toolbar-style rather than a sidebar: six items is under the count where a sidebar
    /// earns its width, and the pane is 440 points wide — a sidebar would eat a third of
    /// it to say what a 22-point icon already says. The pill slides between tabs with
    /// `matchedGeometryEffect`, which is the small thing that makes a strip of buttons
    /// read as one control.
    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { t in
                let on = tab == t
                Button {
                    guard !on else { return }
                    withAnimation(.easeInOut(duration: 0.18)) { storedTab = t.rawValue }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.symbol)
                            .font(.system(size: 14, weight: .regular))
                            .frame(height: 16)
                        Text(t.label)
                            .font(.system(size: 10.5, weight: on ? .semibold : .medium))
                    }
                    .foregroundStyle(on ? Theme.text : Theme.textDim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.fillHi)
                                .matchedGeometryEffect(id: "tabPill", in: tabPill)
                        } else if hoveredTab == t {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.fill)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    withAnimation(.easeOut(duration: 0.12)) {
                        hoveredTab = inside ? t : (hoveredTab == t ? nil : hoveredTab)
                    }
                }
                .help(t.blurb)
                .accessibilityLabel(t.label)
                .accessibilityHint(t.blurb)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .general: generalTab
        case .look:    lookTab
        case .screen:  screenTab
        case .access:  accessTab
        case .dev:     devTab
        case .data:    dataTab
        }
    }


    /// Who it is and how it talks: the personality prompt, the voice, the model, and the
    /// two dials — turn-taking and cost — that decide how it behaves in a conversation.
    @ViewBuilder
    private var generalTab: some View {

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

                QuietField {
                    TextEditor(text: binding(\.systemPrompt))
                        .font(.system(size: 12.5))
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(Theme.text)
                        .frame(height: 110)
                        .accessibilityLabel("Personality instructions for \(kAssistantDisplayName)")
                }
            }


            section("Voice") {
                ChipPicker(options: kVoices, selection: binding(\.voice), columns: 5)
                caption("marin and cedar are the newest and best.")
            }


            section("Model") {
                ChipPicker(options: kModels, selection: binding(\.model), tint: Theme.voice, columns: 3)
                caption("Changing the model takes effect on the next connect.")
            }


            section("Speaking speed") {
                sliderRow(binding(\.speed), 0.5...1.5, String(format: "%.2f×", state.settings.speed),
                          accessibilityLabel: "Speaking speed")
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


            section("Cost mode") {
                SegmentedPicker(options: QualityMode.allCases.map { (value: $0, label: $0.label) },
                                selection: Binding(
                                    get: { state.settings.qualityMode },
                                    set: { state.setQualityMode($0) }),
                                accessibilityPrefix: "Cost mode",
                                font: .system(size: 12))
                caption(state.settings.qualityMode.blurb)
                caption("Frames kept in context: \(state.settings.maxScreenFrames). Each one still in context is re-billed on every turn, so a short history is much cheaper than it looks.")
            }


            Button("Apply to live session") { state.applySettingsLive() }
                .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                .opacity(state.connection == .live ? 1 : 0.4)
                .disabled(state.connection != .live)
    }

    /// Everything visual. Light or dark, what is behind the orb, and whether a small
    /// version of it floats over your other apps.
    ///
    /// The backdrops are two galleries, both always on screen: **Still backdrops**, which
    /// hold one picture, and **Moving backgrounds**, which do not. They used to be one
    /// grid with a Motion tile in it that revealed a second grid underneath — so the six
    /// moving backdrops were a mode you had to switch into before you could even look at
    /// them, and a click on one of their tiles while a still backdrop was up set a value
    /// nothing was reading. Both sections stand on their own now and either one is a
    /// complete choice.
    @ViewBuilder
    private var lookTab: some View {

            // First, above both galleries: it is a decision about the whole app getting
            // out of your way, not a footnote to whichever backdrop you happened to pick.
            // It was previously buried at the bottom of the backdrop grid and only
            // appeared for scenes, which meant it vanished when you switched to Midnight
            // and looked like a setting that had been taken away.
            section("Ambient mode") {
                HStack {
                    Text("Fade everything but the scene")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                    Spacer()
                    NeatToggle(isOn: Binding(
                        get: { state.settings.ambientMode },
                        set: { state.settings.ambientMode = $0; state.noteActivity() }))
                        .accessibilityLabel("Ambient mode")
                }
                caption("After 45 seconds of quiet the panels fade out and leave the scene and the orb. The session keeps running — move the mouse to bring it back.")
                if !state.settings.backdrop.isScene {
                    caption("Nothing to reveal behind \(state.settings.backdrop.label) — this takes effect on one of the painted places or a moving background.")
                }
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


            section("Still backdrops") {
                // Three across, matching the moving gallery below it: the two sections
                // are read together now, and nine tiles in threes is three full rows
                // rather than two-and-a-stray.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                          spacing: 12) {
                    ForEach(Backdrop.stillBackdrops) { b in
                        let on = state.settings.look.isShowing(b)
                        Button {
                            if b == .custom {
                                if let path = BackdropPicker.choose() {
                                    state.settings.backdropImagePath = path
                                    state.settings.look.choose(Backdrop.custom)
                                }
                            } else {
                                state.settings.look.choose(b)
                            }
                        } label: {
                            VStack(spacing: 5) {
                                // The swatch is decoration, never a hit target.
                                SwatchFrame(selected: on, radius: 7) {
                                    ZStack {
                                        if b == .custom {
                                            Rectangle().fill(Theme.fill)
                                            Image(systemName: "photo")
                                                .font(.system(size: 13))
                                                .foregroundStyle(Theme.textDim)
                                        } else {
                                            LinearGradient(colors: b.colors,
                                                           startPoint: .topLeading,
                                                           endPoint: .bottomTrailing)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                }
                                .allowsHitTesting(false)
                                Text(b.label)
                                    .font(.system(size: 10.5, weight: on ? .medium : .regular))
                                    .foregroundStyle(on ? Theme.text : Theme.textDim)
                                    .lineLimit(1)
                            }
                            // The whole tile is the target, and deliberately not the
                            // drawn content's shape.
                            //
                            // A Button's hit region is whatever its label hit-tests to,
                            // so `allowsHitTesting(false)` above — which keeps a live
                            // tile from eating the click — also takes the swatch out of
                            // the button. What is left without this is the one-line
                            // caption underneath, which is a 10-point target for a
                            // 42-point picture. Stating the shape restores the tile
                            // without giving the content its hit test back.
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // The selected backdrop is marked by a ring and a checkmark,
                        // neither of which VoiceOver can see. Say it instead.
                        .accessibilityLabel("Backdrop: \(b.label)")
                        .accessibilityHint(b.blurb)
                        .accessibilityAddTraits(on ? [.isSelected] : [])
                    }
                }
                caption(stillNote)

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
                if state.settings.backdrop.place != nil {
                    caption("The places are painted rather than photographed, so they stay sharp at any size and add nothing to the app\'s two megabytes.")

                    SegmentedPicker(options: [(value: "auto", label: "Auto")]
                                    + Daylight.allCases.map {
                                        (value: $0.rawValue, label: $0.rawValue.prefix(1).uppercased() + $0.rawValue.dropFirst())
                                    },
                                    selection: Binding(
                                        get: { state.settings.daylightMode },
                                        set: { state.settings.daylightMode = $0 }),
                                    accessibilityPrefix: "Daylight")
                    caption(state.settings.daylightMode == "auto"
                            ? "Following your clock — right now it\'s \(Daylight.now().label.lowercased()). The scene changes as the day does."
                            : "Pinned to \(state.settings.daylightMode).")
                }
            }


            // Always here, never behind a toggle: which of the nine and how hard it moves
            // is nine live previews and two controls deep, and none of it can be judged
            // from a 42-point swatch in somebody else\'s grid.
            section("Moving backgrounds") { motionControls }


            section("Camera bubble") {
                HStack {
                    Text("Show my camera, floating")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                    Spacer()
                    NeatToggle(isOn: Binding(
                        get: { state.settings.cameraBubble },
                        set: { state.settings.cameraBubble = $0; state.applyCameraBubble() }))
                }
                caption("A round preview that floats over everything and drags anywhere, like Loom's. It shows before you record too, so you can frame yourself first — and while a recording is running it shows that same camera rather than opening a second one, which is what causes a device-busy failure mid-take.")

                if state.settings.cameraBubble {
                    SegmentedPicker(
                        options: CameraSize.allCases.map { ($0, $0.label) },
                        selection: Binding(get: { state.settings.cameraSize },
                                           set: { state.setCameraSize($0) }),
                        accessibilityPrefix: "Camera size")
                    HStack {
                        Text("Shape").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                        Spacer()
                    }
                    SegmentedPicker(
                        options: CameraShape.allCases.map { ($0, $0.label) },
                        selection: Binding(get: { state.settings.cameraShape },
                                           set: { state.setCameraShape($0) }),
                        accessibilityPrefix: "Camera shape")

                    HStack {
                        Text("Controls on hover")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                        Spacer()
                        NeatToggle(isOn: Binding(
                            get: { state.settings.cameraControls },
                            set: { state.settings.cameraControls = $0; state.applyCameraBubble() }))
                    }
                    caption("Size and shape buttons under the pointer, like Loom's. Turn them off while recording something where a control bar appearing over the picture would be a distraction.")

                    HStack {
                        Text("Mirror me")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                        Spacer()
                        NeatToggle(isOn: Binding(
                            get: { state.settings.cameraMirrored },
                            set: { state.settings.cameraMirrored = $0; state.applyCameraBubble() }))
                    }
                    caption("Off by default, and that is the honest default rather than the flattering one. Loom composites the camera, so it can show you a mirror while recording what everyone else should see. A screen recording captures the bubble as it appears, so mirroring here mirrors the recording too — anything with text in shot comes out backwards.")

                    caption("The same size the bubble\'s own hover controls set, and the same size the camera is drawn at in the recording — that is the point of it being one setting. Full means the camera fills the frame instead of sitting in a corner. Which corner follows wherever you drag the bubble: it is in the \(state.settings.cameraCorner.blurb) now.")
                }
            }

            section("Floating widget") {
                HStack {
                    Text("Keep a widget on top")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                    Spacer()
                    NeatToggle(isOn: Binding(
                        get: { state.settings.hudEnabled },
                        set: { state.settings.hudEnabled = $0; state.applyHUD() }))
                }
                caption("A small panel that floats above other apps and follows you between Spaces and full-screen windows. Drag it anywhere; clicking the orb opens FlowState. It never takes focus, so it cannot interrupt what you are typing.")

                if state.settings.hudEnabled {
                    SegmentedPicker(options: HUDStyle.allCases.map { (value: $0, label: $0.label) },
                                    selection: Binding(
                                        get: { state.settings.hudStyle },
                                        set: { state.settings.hudStyle = $0; state.applyHUD() }),
                                    accessibilityPrefix: "Widget style")
                    caption(state.settings.hudStyle.blurb)
                }
            }
    }

    /// What it can see, and how often. The permission and the display choice sit next to
    /// the switch that uses them, rather than a scroll apart.
    @ViewBuilder
    private var screenTab: some View {

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
                        Text("Screen Recording isn't usable yet — the permission is just below.")
                            .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
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

                caption("How often it looks — and whether it looks without being asked — is the switch at the top of this tab.")
            }
    }

    /// How you reach it from outside its own window, and what it can reach in return.
    @ViewBuilder
    private var accessTab: some View {

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

                // "Off" is one of the choices rather than a switch beside them: turning
                // the shortcut off and picking a different one are the same decision.
                SegmentedPicker(options: HotkeyCombo.summonChoices.map { (value: $0.id, label: $0.label) }
                                        + [(value: "", label: "Off")],
                                selection: Binding(
                                    get: { state.settings.summonHotkey },
                                    set: { state.settings.summonHotkey = $0; state.applySummonHotkey() }),
                                accessibilityPrefix: "Summon shortcut")
                caption("Summons \(kAssistantDisplayName) from any app, and hides it again if it is already in front. ⌘⇧2 still sends a screenshot from anywhere. If a shortcut does nothing, another app already owns it — pick a different one.")

                HStack {
                    Text("Talk to it").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                    Spacer()
                }
                SegmentedPicker(options: HotkeyCombo.connectChoices.map { (value: $0.id, label: $0.label) }
                                        + [(value: "", label: "Off")],
                                selection: Binding(
                                    get: { state.settings.connectHotkey },
                                    set: { state.settings.connectHotkey = $0; state.applyConnectHotkey() }),
                                accessibilityPrefix: "Connect shortcut")
                caption("Control-Shift-F by default. (⌃ is Control, ⇧ is Shift, ⌘ is Command.) Connects from anywhere, and hangs up if a session is already open — without going to find the window first. The point of something always there is that reaching it is not a task. A bare chord like holding ⌃⇧ on its own would need an event tap, and that means an Accessibility prompt, so this asks for a real key instead.")
            }


            section("Let it start the conversation") {
                HStack {
                    Text("Speak up when something finishes")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                    Spacer()
                    NeatToggle(isOn: binding(\.proactive))
                }
                caption("When a coding task finishes, \(kAssistantDisplayName) opens a session and tells you, instead of waiting to be asked. It stays quiet if your screen is locked, if you have been away from the keyboard for three minutes, if a conferencing app is running, or if it interrupted you in the last ten minutes — and anything it sat on for more than two hours it drops rather than announcing as news. Say \"go to sleep\" and it hangs up.")
            }

            section("Wake phrase") {
                HStack {
                    Text("Listen for \"Hey Flow\"")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                    Spacer()
                    NeatToggle(isOn: Binding(
                        get: { state.settings.wakeWord },
                        set: { state.settings.wakeWord = $0; state.applyWakeWord() }))
                }
                SegmentedPicker(options: [("heyFlow", "Hey Flow"), ("heyFlowState", "Hey FlowState")],
                                selection: Binding(
                                    get: { state.settings.wakePhrase },
                                    set: { state.settings.wakePhrase = $0; state.applyWakeWord() }),
                                accessibilityPrefix: "Wake phrase")
                caption("Recognition runs on-device — the audio never leaves this Mac, and it works with no network. It does hold the microphone open whenever no session is running, which costs battery. Two words on purpose: \"flow\" on its own is a word you say constantly, including as the name of another app, and it will not wake on that.")
                HStack {
                    Text("Two claps also wake it")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                    Spacer()
                    NeatToggle(isOn: Binding(
                        get: { state.settings.clapToWake },
                        set: { state.settings.clapToWake = $0; state.applyWakeWord() }))
                }
                caption("No recogniser involved — a clap is the sharpest, loudest thing that happens in a quiet room, and that shape is visible in the samples directly. It works across a room where the phrase often does not. Two claps rather than one, roughly a quarter-second apart: one loud noise is a door, a mug, a laptop lid.")

                if !state.wake.lastHeard.isEmpty {
                    caption("Last heard: \(state.wake.lastHeard)")
                }
            }

            section("Tuning the wake trigger") {
                WakeTuningView(state: state)
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


            section("Notion") {
                SecureTokenField(
                    placeholder: "ntn_… integration token",
                    isSet: Notion.isConfigured,
                    onSave: { try? KeyStore.setSecret($0, forKey: "NOTION_TOKEN") })
                caption("Create an internal integration at notion.so/my-integrations, then share the pages you want \(kAssistantDisplayName) to see with it — it can only read what you share. The token is written to the same 0600 file as your OpenAI key, outside the repo.")
            }
    }

    /// The one tab where a switch can change files on this Mac. Kept on its own for that
    /// reason: nothing here should be stumbled into while looking for a slider.
    @ViewBuilder
    private var devTab: some View {

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
                    QuietField {
                        TextField("~/dev/vibe-voice", text: Binding(
                            get: { state.settings.devRepo },
                            set: { state.settings.devRepo = $0 }))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .accessibilityLabel("Repository Dev Mode works in")
                    }
                    Text("Every task runs here, and nowhere else.")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                }

                devToggle("Commit each task when it finishes",
                          "Only what the task itself changed is committed — anything you already "
                          + "had in progress is left alone, because the restore point taken "
                          + "beforehand is what it diffs against. Commits land on your current "
                          + "branch, and each task also gets a flowstate/T1-… branch to review or "
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
    }

    /// What survives the conversation — recordings on disk, transcripts, summaries, and
    /// the switches that decide how much of any of it is kept.
    @ViewBuilder
    private var dataTab: some View {

            captureSection

            section("Recordings") {
                HStack {
                    Text(state.isRecording ? "Recording now" : "Not recording")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                    // Seconds actually in the buffer, not seconds since the
                    // button was pressed. The two are the same when it is
                    // working and tell you a great deal when it is not.
                    if state.isRecording {
                        Text(String(format: "%d:%02d",
                                    Int(state.recorder.duration) / 60,
                                    Int(state.recorder.duration) % 60))
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(state.recorder.duration > 0 ? Theme.bad : Theme.textFaint)
                    }
                    Spacer()
                    Button(state.isRecording ? "Stop" : "Record") {
                        _ = state.isRecording ? state.stopRecording() : state.startRecording()
                    }
                    .buttonStyle(GhostButtonStyle(tint: state.isRecording ? Theme.badInk : Theme.accentInk))
                    .disabled(!state.isRecording && !state.audio.running)
                    .opacity(state.isRecording || state.audio.running ? 1 : 0.5)
                    .help(state.isRecording
                          ? "Stop and write the file"
                          : (state.audio.running
                             ? "Record both halves of this conversation"
                             : "Connect first — there is no microphone running to record from"))
                }
                caption("Captures both halves — your voice and its replies — into one WAV. Nothing extra is recorded to do it: both sides already pass through the app as audio on their way to and from OpenAI.")

                // The last output, in full: what was written, where it went, and
                // the two things worth doing with it. Same card as the stage —
                // but falling back to the newest file on disk, because the stage
                // card is about something that just happened and this one is
                // about where your recordings are, which outlives a launch.
                if let last = latestRecording {
                    RecordingResultCard(file: last.described,
                                        title: "Latest recording",
                                        problem: state.recordingProblem(for: last.url),
                                        onPlay: { state.play(last.url) },
                                        onReveal: { state.reveal(last.url) })
                } else if let problem = state.recordingIssue?.message {
                    // No card to carry it, but a click that did nothing still
                    // owes the user a reason.
                    RecordingProblemLine(message: problem)
                }

                // A recorder that refused, or ran and captured nothing, used to
                // say so only in the transcript — where it scrolled away.
                if let problem = state.recordingError {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9.5)).foregroundStyle(Theme.badInk)
                            .padding(.top, 2)
                        Text(problem)
                            .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }

                if state.recordings.isEmpty {
                    caption("Nothing recorded yet.")
                } else {
                    ForEach(state.recordings.prefix(8)) { r in
                        HStack(spacing: 8) {
                            // Read off the extension rather than hard-coded: the folder
                            // now holds two kinds of file, and a waveform next to a screen
                            // recording is the list quietly lying about what it has.
                            Image(systemName: r.url.pathExtension.lowercased() == "mov"
                                  ? "film" : "waveform")
                                .font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                            Text(r.title)
                                .font(.system(size: 11.5)).foregroundStyle(Theme.text)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(r.lengthLabel)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textFaint)
                            Button { state.play(r.url) } label: {
                                Image(systemName: "play.fill").font(.system(size: 9))
                            }
                            .buttonStyle(.plain).foregroundStyle(Theme.accentInk)
                            .help("Play")
                            .accessibilityLabel("Play \(r.title)")
                            // Per row, not just for the newest: "Open in Finder"
                            // at the bottom of the list always revealed the top
                            // one, which is the wrong file whenever you are
                            // looking for any of the others.
                            Button { state.reveal(r.url) } label: {
                                Image(systemName: "folder").font(.system(size: 9))
                            }
                            .buttonStyle(.plain).foregroundStyle(Theme.textDim)
                            .help("Open in Finder")
                            .accessibilityLabel("Open \(r.title) in Finder")
                            .accessibilityHint("Shows it in Finder")
                        }
                        // Reported against the row that was clicked. Anywhere
                        // else and it reads as a complaint about a file the user
                        // never touched — and not here at all when the card above
                        // is about this same file and is already carrying it.
                        if latestRecording?.url != r.url,
                           let problem = state.recordingProblem(for: r.url) {
                            RecordingProblemLine(message: problem)
                        }
                    }
                    Button("Open in Finder") { state.revealRecordings() }
                        .buttonStyle(GhostButtonStyle())
                        .accessibilityLabel("Open in Finder")
                        .accessibilityHint("Shows the newest recording in Finder")
                }
            }
            .onAppear { state.refreshRecordings() }


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
    }

    private var savedConversationsLine: String {
        let n = state.sessions.count
        guard n > 0 else { return "Nothing saved yet." }
        return "\(n) saved" + (state.settings.privacy.persistToDisk
                               ? "." : " — but \"Save to disk\" is off, so they go when \(kAssistantDisplayName) quits.")
    }

    // MARK: - Moving backdrops

    /// The picker for `Backdrop.motion`, which lives in `MotionStyleGallery` so it can be
    /// rendered — and looked at — without a Settings pane around it.
    ///
    /// It is handed the whole `LookSelection` rather than just the style, because picking
    /// a moving background has to switch the backdrop to `.motion` too. With only the
    /// style to write, a click here while a still backdrop was showing changed a value
    /// nothing on screen was reading.
    private var motionControls: some View {
        MotionStyleGallery(look: binding(\.look),
                           intensity: binding(\.motionIntensity),
                           assetsEnabled: binding(\.motionAssets),
                           installError: $motionInstallError)
    }

    /// What the record button captures, how big that is, and whether there is room.
    ///
    /// It sits above the recordings list rather than in the Screen tab, because the
    /// question it answers is "what goes in the file", and the file is what this whole
    /// tab is about. The Screen tab is about what the *assistant* is allowed to look at,
    /// which is a different permission and a different decision.
    @ViewBuilder
    private var captureSection: some View {
        let mode = state.settings.captureMode
        let plan = state.capturePlan(for: mode)
        let advice = state.storageAdvice

        section("What to capture") {
            SegmentedPicker(options: CaptureMode.allCases.map { (value: $0, label: $0.label) },
                            selection: Binding(
                                get: { state.settings.captureMode },
                                set: { newMode in
                                    state.settings.captureMode = newMode
                                    // Ask for the permission now, while the user is
                                    // thinking about cameras — not at the instant they
                                    // press record, when a dialog is just in the way.
                                    Task { await state.prepareCapture(for: newMode) }
                                }),
                            accessibilityPrefix: "Capture",
                            font: .system(size: 12))
            caption(mode.blurb)

            if mode.isVideo {
                SegmentedPicker(options: PerformanceProfile.allCases.map { (value: $0, label: $0.label) },
                                selection: Binding(
                                    get: { state.settings.capturePerformance },
                                    set: {
                                        state.settings.capturePerformance = $0
                                        state.refreshFreeSpace()
                                    }),
                                accessibilityPrefix: "Quality",
                                font: .system(size: 12))
                caption(state.settings.capturePerformance.blurb)

                // The three numbers that decide the size. Not the size itself — that is
                // the line below, and printing it twice made the pane look like it was
                // arguing with itself.
                Text(plan.summary)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Recording at \(plan.width) by \(plan.height), "
                                        + "\(plan.frameRate) frames per second, \(plan.codec.label)")
            }

            if mode.capturesCamera { cameraRow }

            storageRow(advice)

            if let refusal = state.permissionRefusal(for: mode) {
                RecordingProblemLine(message: refusal)
                HStack(spacing: 8) {
                    if mode.capturesCamera, !CameraCapture.permission().canCapture {
                        Button("Open Camera settings") { CameraCapture.openPrivacySettings() }
                            .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                    }
                    if mode.capturesScreen, state.screenPermission.blocksCapture {
                        Button(state.screenPermission == .needsRestart
                               ? "Relaunch \(kSystemAppName)" : "Open Screen Recording settings") {
                            state.screenPermission == .needsRestart
                                ? ScreenCapture.relaunch()
                                : ScreenCapture.openPrivacySettings()
                        }
                        .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                    }
                }
            }

            caption("Audio-only is unchanged from every earlier build: one 24 kHz WAV, in "
                    + "the same folder, holding both halves of the conversation. The video "
                    + "modes add a QuickTime movie with that same audio on it — nothing is "
                    + "recorded twice, and the microphone mixdown is identical either way.")
        }
        .onAppear { state.refreshFreeSpace(); Task { await state.prepareCapture(for: state.settings.captureMode) } }
    }

    /// Which camera. A menu rather than chips: camera names run to "FaceTime HD Camera
    /// (Built-in)" and a chip row of those is unreadable at 440 points.
    @ViewBuilder
    private var cameraRow: some View {
        let selected = state.cameras.first { $0.id == state.settings.cameraDeviceID }
            ?? state.cameras.first { $0.isDefault }
            ?? state.cameras.first

        HStack {
            Text("Camera").font(.system(size: 12.5)).foregroundStyle(Theme.text)
            Spacer()
            if state.cameras.isEmpty {
                Text("None connected")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
            } else {
                Menu {
                    ForEach(state.cameras) { camera in
                        Button {
                            state.settings.cameraDeviceID = camera.id
                            // Re-plan: a different camera can be a different resolution,
                            // which is a different estimate on the line above.
                            Task { await state.prepareCapture(for: state.settings.captureMode) }
                        } label: {
                            Text(camera.menuLabel + (camera.id == selected?.id ? "  ✓" : ""))
                        }
                    }
                } label: {
                    Text(selected?.name ?? "Choose…")
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 200)
                .accessibilityLabel("Camera")
                .accessibilityValue(selected?.name ?? "none")
            }
        }
        if let selected, !selected.resolution.isEmpty {
            caption("\(selected.name) — \(selected.resolution) native. "
                    + "It is scaled down before it is written; see the size above.")
        }
    }

    /// Disk: what this costs, what is free, and how worried to be. Always present, even
    /// when the answer is "plenty" — the number is the point, the warning is the
    /// exception.
    private func storageRow(_ advice: StorageAdvice) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: advice.symbol)
                .font(.system(size: 10))
                .foregroundStyle(advice.level == .critical ? Theme.badInk
                                 : advice.level == .caution ? Theme.accentInk : Theme.textFaint)
                .padding(.top, 1.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(advice.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(advice.isWarning ? Theme.textDim : Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                if state.recordingsFreeBytes > 0 {
                    Text("\(RecordingFile.size(state.recordingsFreeBytes)) free on this disk.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textFaint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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

    /// A line of explanation under a control.
    ///
    /// `fixedSize` vertically is not decoration: without it a long caption is free to
    /// truncate to one line with an ellipsis when the layout is under pressure, which is
    /// how a sentence explaining what a switch does silently becomes half a sentence.
    private func caption(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
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
