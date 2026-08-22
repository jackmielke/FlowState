import SwiftUI
import AppKit

/// The little always-there widget, like the one Wispr Flow floats on the desktop.
///
/// Three AppKit facts do all the work here, and getting any of them wrong produces a
/// window that is technically on top and horrible to live with:
///
///  1. **`.nonactivatingPanel`.** Clicking the widget must not pull focus out of whatever
///     you were typing in. An ordinary window steals first responder the moment it is
///     touched, which for a thing that sits over your editor is unusable.
///  2. **Level `.screenSaver` (1000).** Inspecting Wispr Flow's own overlay shows exactly
///     this — `layer=1000`. `.floating` sits below full-screen apps, so a widget at that
///     level vanishes the moment you full-screen anything.
///  3. **`.canJoinAllSpaces` + `.fullScreenAuxiliary`.** Without these it belongs to the
///     Space it was born on and does not follow you between desktops.
///
/// Dragging is `isMovableByWindowBackground`, i.e. AppKit's own. That is the answer to
/// "the smoother the better": the window server moves the window, so it tracks perfectly
/// and costs nothing, where a SwiftUI DragGesture re-lays-out on every frame.
final class HUDPanel: NSPanel {

    init(content: NSView, size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        // The widget is black in both system appearances, so it has to *be* dark as far
        // as AppKit is concerned. Theme's tokens resolve against the drawing view's
        // appearance; leave this on aqua and every label inside paints near-black on
        // black the moment someone switches the desktop to light mode.
        appearance = NSAppearance(named: .darkAqua)
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        // Otherwise a borderless panel refuses key events and the buttons inside go dead.
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .utilityWindow

        // The size comes from the style, NOT from asking the hosting view to lay itself
        // out here. `fittingSize` inside init runs a SwiftUI layout pass while the app's
        // scene graph is still being built, which aborts the process outright
        // (AG::precondition_failure) rather than failing gracefully.
        contentView = content
    }

    // A borderless panel is not key-eligible by default, which would leave everything
    // inside it unclickable.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Bottom-right of the screen the pointer is on, inset like a notification.
    func moveToDefaultCorner() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = frame.size
        setFrameOrigin(CGPoint(x: visible.maxX - size.width - 24,
                               y: visible.minY + 24))
    }

    /// Keeps the widget on screen after a monitor is unplugged or resolution changes.
    func nudgeBackOnScreen() {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = frame
        f.origin.x = min(max(f.origin.x, visible.minX + 8), visible.maxX - f.width - 8)
        f.origin.y = min(max(f.origin.y, visible.minY + 8), visible.maxY - f.height - 8)
        if f.origin != frame.origin { setFrameOrigin(f.origin) }
    }
}

/// Owns the panel's lifetime and keeps it in step with the settings.
@MainActor
final class HUDController {
    private var panel: HUDPanel?
    private weak var state: AppState?

    init(state: AppState) { self.state = state }

    func apply() {
        guard let state else { return }
        state.settings.hudEnabled ? show() : hide()
    }

    private func show() {
        guard let state else { return }
        if panel == nil {
            let host = NSHostingView(rootView: HUDView(state: state))
            host.autoresizingMask = [.width, .height]
            let p = HUDPanel(content: host, size: state.settings.hudStyle.size)
            p.moveToDefaultCorner()
            panel = p
            // A display change can leave it stranded off-screen.
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { [weak p] _ in
                    MainActor.assumeIsolated { p?.nudgeBackOnScreen() }
                }
        }
        if let p = panel {
            let want = state.settings.hudStyle.size
            if p.frame.size != want {
                // Grow from the same corner it is anchored to, so switching style does
                // not walk the widget across the screen.
                var f = p.frame
                f.origin.x += f.width - want.width
                f.size = want
                p.setFrame(f, display: true)
            }
        }
        panel?.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
