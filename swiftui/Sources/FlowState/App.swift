import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the window used to quit the app — and quitting the app unregisters every
    /// global hotkey, because a Carbon hotkey belongs to a process. So the wake key
    /// worked until the first time somebody hit ⌘W, and then silently did not, which is
    /// indistinguishable from the key never having been bound.
    ///
    /// It still quits when there is genuinely no way back in: no menu bar icon and no
    /// wake key means a windowless FlowState is a process the user cannot reach and
    /// cannot see, which is worse than one that closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool {
        guard let settings = AppState.current?.settings else { return true }
        return !(settings.menuBarEnabled || !settings.wakeHotkey.isEmpty)
    }

    /// Clicking the Dock icon with no window open.
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppState.current?.reopenMainWindow?() }
        return true
    }

}

/// Keeps a way to reopen the main window after it is closed. See
/// `AppState.reopenMainWindow` for why this cannot be done from AppKit.
private struct WindowReopener: View {
    @Environment(\.openWindow) private var openWindow
    let state: AppState

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { state.reopenMainWindow = { openWindow(id: "main") } }
    }
}

@main
struct FlowStateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("FlowState", id: "main") {
            ContentView(state: state)
                .ignoresSafeArea(.all, edges: .top)
                // Renders Settings to PNGs and quits, when FLOWSTATE_SNAPSHOT is set.
                // Does nothing at all otherwise — see SettingsSnapshot.
                .task { await SettingsSnapshot.runIfRequested(state: state) }
                // Also a no-op unless asked for — see RecordingSmokeTest.
                .task { await RecordingSmokeTest.runIfRequested(state: state) }
                .background(WindowReopener(state: state))
                // `flowstate://connect`, from Shortcuts, Raycast, a script — anything
                // that is already running when this app is not. See `DeepLink`.
                //
                // NOT `application(_:open:)` on the delegate: `@NSApplicationDelegateAdaptor`
                // installs SwiftUI's own delegate in front of ours, and it consumes the
                // URL event without forwarding it. Measured — the delegate method was
                // never called for a `flowstate://` URL that LaunchServices had already
                // matched to this bundle. This is the route SwiftUI actually delivers on.
                .onOpenURL { DeepLink.handle($0) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1080, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                // Where every other Mac app puts it. The default File > New is removed
                // because this app has no documents — but it does have conversations,
                // and this is the shortcut people will try first.
                Button("New Conversation") { state.newConversation() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("View") {
                ForEach(AppearanceMode.allCases, id: \.self) { m in
                    // Spelled-out checkmark rather than a Label/Picker: menu items are
                    // the one place the current choice has to be readable with no
                    // dependence on how the SDK decides to render menu glyphs.
                    Button(state.settings.appearance == m ? "✓ \(m.label)" : "    \(m.label)") {
                        state.settings.appearance = m
                        m.applyToApp()
                    }
                    .keyboardShortcut(m.shortcut, modifiers: [.command, .option])
                }
            }
            CommandMenu("Session") {
                Button("Connect / Disconnect") { state.toggleConnection() }
                    .keyboardShortcut("k", modifiers: .command)
                // Listed so the wake key is discoverable somewhere other than Settings.
                // No `.keyboardShortcut` — the binding is a global Carbon hotkey and is
                // user-chosen, and declaring it here as well would register a second,
                // menu-local copy that fights the real one.
                Button("Wake and Listen (\(HotkeyCombo.named(state.settings.wakeHotkey).label))") {
                    state.wakeAndConnect(from: "menu")
                }
                .disabled(state.settings.wakeHotkey.isEmpty)
                // Its opposite, for the same reason: the deactivate key is Esc by
                // default and Esc is deliberately not bound while this app is in front,
                // so somebody looking at the window needs a visible way to stop.
                Button("Stop Everything\(state.settings.hushHotkey.isEmpty ? "" : " (\(HotkeyCombo.named(state.settings.hushHotkey).label))")") {
                    state.hush()
                }
                Button("Send Screenshot") { Task { await state.captureAndSend(auto: false) } }
                    .keyboardShortcut("2", modifiers: [.command, .shift])
                Button("Settings…") { state.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        // Flow in the menu bar. A separate Scene, placed AFTER the Window and its
        // .commands — chained onto them instead, it silently attaches the command menus
        // to the wrong scene and no status item appears.
        MenuBarExtra("FlowState", systemImage: state.menuBarSymbol,
                     // Idempotent on purpose: SwiftUI assigns to this during evaluation,
                     // and an unconditional write here re-entered the whole update cycle.
                     isInserted: Binding(
                        get: { state.settings.menuBarEnabled },
                        set: { if state.settings.menuBarEnabled != $0 { state.settings.menuBarEnabled = $0 } })) {
            MenuBarMenu(state: state)
        }
    }
}

/// The menu behind the menu-bar icon.
///
/// Everything here is something you would want without the window in front: whether a
/// session is live, what it is costing, whether a task is running, and the two actions
/// worth reaching for blind — connect, and show it your screen.
struct MenuBarMenu: View {
    @ObservedObject var state: AppState

    var body: some View {
        Text(state.connection.label + (state.sessionID == nil ? "" : " · session open"))
        Text(state.currentSessionTitle)

        if state.cost.turns > 0 {
            Text("$" + state.cost.formatted + " this session")
        }

        Divider()

        Button(state.connection == .live ? "Disconnect" : "Connect") {
            state.toggleConnection()
        }
        .keyboardShortcut("k", modifiers: .command)

        // Chords named rather than bound: these are user-chosen global hotkeys, and a
        // `.keyboardShortcut` here would register a second, menu-local copy fighting the
        // real one. The label is the only honest way to make them discoverable from
        // outside Settings.
        if state.connection != .live {
            Button("Wake and listen\(shortcutSuffix(state.settings.wakeHotkey))") {
                state.wakeAndConnect(from: "menubar")
            }
        } else {
            Button("Stop everything\(shortcutSuffix(state.settings.hushHotkey))") {
                state.hush()
            }
        }

        Button("New conversation") { state.newConversation() }
            .keyboardShortcut("n", modifiers: .command)

        Button("Show it my screen") {
            Task { @MainActor in await state.captureAndSend(auto: false) }
        }
        .disabled(state.connection != .live)

        if state.devTasks.running.isEmpty == false {
            Divider()
            ForEach(state.devTasks.running) { t in
                Button("Stop \(t.id) — \(t.label)") {
                    Task { @MainActor in await state.cancelTask(t.id) }
                }
            }
        }

        Divider()

        Button("Open FlowState") { Summon.toggle() }
        Button("Settings…") { Summon.toggle(); state.showSettings = true }

        Divider()
        Button("Quit FlowState") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)

    }

    /// " (⌃Q)", or nothing at all when that row is switched off.
    private func shortcutSuffix(_ id: String) -> String {
        id.isEmpty ? "" : " (" + HotkeyCombo.named(id).label + ")"
    }
}
