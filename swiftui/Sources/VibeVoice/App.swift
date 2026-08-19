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
        .commands {
            CommandGroup(replacing: .newItem) {}
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
