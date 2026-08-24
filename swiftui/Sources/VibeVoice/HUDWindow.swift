import SwiftUI
import AppKit
import VibeVoiceCore

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
/// Hosts the widget and refuses clicks that miss it.
///
/// The panel is deliberately larger than the thing you can see, so the glow has room to
/// spill instead of being clipped at the edge. That margin is transparent, and a
/// transparent part of a window still swallows clicks — which would leave an invisible
/// dead zone around the widget where the desktop stopped responding. So the margin is
/// made literally click-through: anything outside the drawn surface hit-tests to nil and
/// the click goes to whatever is behind.
final class HUDContainerView: NSView {
    /// The drawn shape, inset from the panel's bounds.
    var surface: CGSize = .zero
    var corner: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        let r = NSRect(x: (bounds.width  - surface.width)  / 2,
                       y: (bounds.height - surface.height) / 2,
                       width: surface.width, height: surface.height)
        // Rounded, so the corners of the bounding box are click-through too.
        let path = NSBezierPath(roundedRect: r, xRadius: corner, yRadius: corner)
        return path.contains(point) ? super.hitTest(point) : nil
    }
}

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

    /// Moves to the same corner of another screen, following the work.
    ///
    /// The corner, not the default corner: the widget is draggable, so wherever it is
    /// sitting is somewhere the user put it. Parked 24 points in from the bottom-right it
    /// arrives 24 points in from the bottom-right, on a display of any size. The
    /// arithmetic is in `ActiveScreenOverlay`, where it can be tested without owning a
    /// second monitor.
    func follow(screen next: NSScreen) {
        let visible = next.visibleFrame
        // `NSWindow.screen` is nil for a panel that has not been ordered front yet, which
        // is the case on the very first placement. Nothing to move *from*, so clamp onto
        // the target instead of guessing a corner to preserve.
        guard let current = screen else {
            return setFrameOrigin(ActiveScreenOverlay.clamped(frame, in: visible))
        }
        guard current !== next else { return }
        setFrameOrigin(ActiveScreenOverlay.moved(frame, from: current.visibleFrame, to: visible))
    }

    /// Keeps the widget on screen after a monitor is unplugged or resolution changes.
    func nudgeBackOnScreen() {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let origin = ActiveScreenOverlay.clamped(frame, in: visible)
        if origin != frame.origin { setFrameOrigin(origin) }
    }
}

/// Owns the panel's lifetime and keeps it in step with the settings.
@MainActor
final class HUDController {
    private var panel: HUDPanel?
    private weak var state: AppState?

    /// The active screen, remembered so a widget switched on later starts in the right
    /// place instead of wherever the pointer happened to be at that instant.
    private var displayID: CGDirectDisplayID?

    init(state: AppState) { self.state = state }

    func apply() {
        guard let state else { return }
        state.settings.hudEnabled ? show() : hide()
    }

    /// Follows the screen being worked on, the way the captions and the camera bubble do.
    ///
    /// An id that no longer matches an attached display is remembered but not acted on:
    /// the widget stays where it is rather than being flung at a monitor that has been
    /// unplugged. `nudgeBackOnScreen` already handles that case on its own notification.
    func followDisplay(_ id: CGDirectDisplayID?) {
        guard displayID != id else { return }
        displayID = id
        guard let panel, let screen = Self.screen(for: id) else { return }
        panel.follow(screen: screen)
    }

    private static func screen(for id: CGDirectDisplayID?) -> NSScreen? {
        guard let id else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    private func show() {
        guard let state else { return }
        if panel == nil {
            let style = state.settings.hudStyle
            let host = NSHostingView(rootView: HUDView(state: state))
            host.autoresizingMask = [.width, .height]
            let container = HUDContainerView(frame: NSRect(origin: .zero, size: style.size))
            container.surface = style.surface
            container.corner = style.corner
            container.autoresizesSubviews = true
            host.frame = container.bounds
            container.addSubview(host)
            let p = HUDPanel(content: container, size: style.size)
            p.moveToDefaultCorner()
            // Switched on while the pointer is elsewhere: land on the active screen
            // rather than the one the default corner happened to pick.
            if let screen = Self.screen(for: displayID) { p.follow(screen: screen) }
            panel = p
            // A display change can leave it stranded off-screen.
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { [weak p] _ in
                    MainActor.assumeIsolated { p?.nudgeBackOnScreen() }
                }
        }
        if let p = panel {
            let style = state.settings.hudStyle
            if let c = p.contentView as? HUDContainerView {
                c.surface = style.surface
                c.corner = style.corner
            }
            let want = style.size
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
