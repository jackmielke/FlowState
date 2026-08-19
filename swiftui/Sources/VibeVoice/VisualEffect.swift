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

/// Applies the frameless / full-size-content chrome once the window exists.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.isMovableByWindowBackground = true
            w.backgroundColor = .clear
            w.appearance = NSAppearance(named: .darkAqua)
            w.standardWindowButton(.zoomButton)?.isHidden = false
            w.minSize = NSSize(width: 940, height: 620)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            FileHandle.standardError.write(Data("[app] windowNumber=\(w.windowNumber)\n".utf8))
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}
