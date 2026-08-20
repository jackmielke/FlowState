import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

@main
struct VibeVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("Vibe Voice", id: "main") {
            ContentView(state: state)
                .ignoresSafeArea(.all, edges: .top)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1080, height: 700)
        // Flow in the menu bar: reachable without finding its window, and a glance at
        // whether it is live. Deliberately not `.menuBarExtraStyle(.window)` — a menu is
        // what people expect here, and it stays keyboard-navigable.
        MenuBarExtra(isInserted: .constant(true)) {
            MenuBarMenu(state: state)
        } label: {
            Image(systemName: state.menuBarSymbol)
        }

        .commands {
            CommandGroup(replacing: .newItem) {}
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
                Button("Send Screenshot") { Task { await state.captureAndSend(auto: false) } }
                    .keyboardShortcut("2", modifiers: [.command, .shift])
                Button("Settings…") { state.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
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

        if state.cost.turns > 0 {
            Text("$" + state.cost.formatted + " this session")
        }

        Divider()

        Button(state.connection == .live ? "Disconnect" : "Connect") {
            state.toggleConnection()
        }
        .keyboardShortcut("k", modifiers: .command)

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

        Button("Open Flow") { Summon.toggle() }
        Button("Settings…") { Summon.toggle(); state.showSettings = true }

        Divider()
        Button("Quit Flow") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
