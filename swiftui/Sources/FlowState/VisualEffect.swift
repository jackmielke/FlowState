import SwiftUI
import AppKit

/// NSVisualEffectView behind the whole SwiftUI hierarchy.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// Drag-anywhere handle for the hidden-titlebar window.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDragged(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil) }
        }
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ v: NSView, context: Context) {}
}

/// Applies the frameless / full-size-content chrome once the window exists, and keeps
/// the window's appearance in step with the user's theme choice.
struct WindowConfigurator: NSViewRepresentable {
    var appearance: AppearanceMode = .system

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let mode = appearance
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            // Keep .titled — dropping it (or going borderless) is what loses the
            // system corner rounding and the traffic lights.
            w.styleMask.insert(.titled)
            w.styleMask.insert(.fullSizeContentView)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isOpaque = false
            w.backgroundColor = .clear
            // nil = inherit from NSApp, which is what tracks the system live.
            w.appearance = mode.nsAppearance
            // Belt and braces: clip our own content to the same radius the
            // system uses, so no child view paints square past the corner.
            if let cv = w.contentView {
                cv.wantsLayer = true
                cv.layer?.cornerRadius = 12
                cv.layer?.cornerCurve = .continuous
                cv.layer?.masksToBounds = true
            }
            w.standardWindowButton(.zoomButton)?.isHidden = false
            w.minSize = NSSize(width: 940, height: 620)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            FileHandle.standardError.write(Data("[app] windowNumber=\(w.windowNumber)\n".utf8))
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        v.window?.appearance = appearance.nsAppearance
    }
}
