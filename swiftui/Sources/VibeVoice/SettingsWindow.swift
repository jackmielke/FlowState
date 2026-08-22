import SwiftUI
import AppKit

/// Settings as an actual macOS window.
///
/// It used to be a panel drawn inside the main window, moved by a SwiftUI `DragGesture`
/// that recomputed a position on every frame and re-laid-out the whole view to apply it.
/// That is why it felt glitchy however much the maths was tidied: dragging a view is not
/// the same thing as moving a window, and the difference is visible.
///
/// This is a real `NSPanel`. AppKit's window server moves it, so it tracks the cursor
/// exactly, the traffic lights work, it can be resized from any edge, and it remembers
/// where it was left. All of that is behaviour nobody had to write.
///
/// A panel rather than a window because it should float above the app it configures and
/// should not appear in the Window menu as a peer of the conversation.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var panel: NSPanel?
    private weak var state: AppState?
    private static let frameKey = "SettingsPanelFrame"

    init(state: AppState) {
        self.state = state
        super.init()
    }

    func show() {
        guard let state else { return }
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                // .titled is what gives the native title bar, and with it the native
                // drag, the close button and the system corner rounding.
                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                backing: .buffered,
                defer: false)
            p.title = "Settings"
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.becomesKeyOnlyIfNeeded = false
            p.minSize = NSSize(width: 460, height: 420)
            p.delegate = self
            p.contentView = NSHostingView(rootView: SettingsView(state: state))
            // Remembers its own position and size between openings, which is the other
            // half of behaving like a window.
            p.setFrameAutosaveName(Self.frameKey)
            if p.frame.origin == .zero { p.center() }
            panel = p
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    func hide() { panel?.orderOut(nil) }

    /// Closing by the red button has to put the flag back, or the button that opens it
    /// stops working until something else toggles it.
    func windowWillClose(_ notification: Notification) {
        state?.showSettings = false
    }
}
