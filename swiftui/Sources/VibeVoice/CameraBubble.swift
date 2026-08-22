import SwiftUI
import AppKit
import AVFoundation
import VibeVoiceCore

/// Your face, floating, while you record — the thing Loom puts in the corner.
///
/// This is a preview, not a second capture. `VideoCapture` already owns the device for
/// the recording itself; opening a whole second `AVCaptureSession` on the same camera is
/// how you get a device-busy error mid-demo. So when a recording is running the bubble
/// shows the session that is already running, and when nothing is recording it opens its
/// own session purely so you can frame yourself before you start.
///
/// What it looks like is not decoration: `CameraOverlay` describes the size, the corner
/// and the circle once, and both this bubble and the composite written into the movie
/// read it. That is the whole point of the type — before it existed the bubble was a
/// circle you could park anywhere and the recording was a square pinned bottom-right.
final class CameraBubblePanel: NSPanel {

    /// Called after the user drags it, with the panel's new centre in screen coordinates.
    var onMoved: ((CGPoint, NSScreen?) -> Void)?

    init(view: NSView, diameter: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: diameter, height: diameter),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        // The shadow is drawn by the rounded content, not by the square panel, or a
        // circular bubble gets a rectangular drop shadow behind it.
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        contentView = view
    }

    override var canBecomeKey: Bool { false }   // never takes focus from what you are showing
    override var canBecomeMain: Bool { false }

    /// Resizes about the centre, so changing size does not also move the bubble.
    func setDiameter(_ d: CGFloat) {
        guard abs(frame.width - d) > 0.5 else { return }
        let c = CGPoint(x: frame.midX, y: frame.midY)
        setFrame(NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d), display: true)
    }

    func moveToDefaultCorner() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let v = screen?.visibleFrame else { return }
        setFrameOrigin(CGPoint(x: v.maxX - frame.width - 28, y: v.minY + 28))
    }

    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(point)
        onMoved?(CGPoint(x: frame.midX, y: frame.midY), screen)
    }
}

/// The live picture.
///
/// `AVCaptureVideoPreviewLayer` rather than drawing frames ourselves: it is hardware-fed,
/// costs almost nothing, and stays smooth while ScreenCaptureKit and the encoder are also
/// running — which is exactly when a hand-rolled preview would start dropping frames.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession?

    final class View: NSView {
        private var preview: AVCaptureVideoPreviewLayer?
        private weak var attached: AVCaptureSession?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        func attach(_ session: AVCaptureSession?) {
            guard session !== attached else { return }
            attached = session
            preview?.removeFromSuperlayer()
            preview = nil
            guard let session else { return }
            let p = AVCaptureVideoPreviewLayer(session: session)
            p.videoGravity = .resizeAspectFill
            p.frame = bounds
            layer?.addSublayer(p)
            preview = p
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview?.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> View {
        let v = View()
        v.attach(session)
        return v
    }

    func updateNSView(_ v: View, context: Context) { v.attach(session) }
}

/// The bubble itself, with the size controls that appear under the cursor.
struct CameraBubbleView: View {
    @ObservedObject var state: AppState
    var session: AVCaptureSession?

    @State private var hovering = false

    private var size: CameraSize { state.settings.cameraSize }

    var body: some View {
        ZStack {
            CameraPreview(session: session)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 2))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)

            if size.isFullFrame {
                // A round preview cannot show what a full-frame recording will look
                // like, so it says so rather than implying the circle is the crop.
                Text("Full frame")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .offset(y: -geometryOffset)
            }

            if hovering { controls.transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .padding(6)   // room for the shadow, which the panel does not draw
    }

    private var geometryOffset: CGFloat { size.diameter * 0.28 }

    /// Loom's control: pick a size, or send the camera full frame. Sits inside the
    /// circle so it never widens the panel — a wider panel would mean a wider
    /// click-blocking rectangle over whatever is being demonstrated.
    private var controls: some View {
        HStack(spacing: 3) {
            ForEach(CameraSize.allCases) { s in
                Button { state.setCameraSize(s) } label: {
                    Text(s == .full ? "⤢" : String(s.label.prefix(1)))
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(s == size ? Color.accentColor : .white.opacity(0.16)))
                        .foregroundStyle(.white)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(s == .full ? "Camera fills the recording" : "\(s.label) camera")
            }
        }
        .padding(4)
        .background(Capsule().fill(.black.opacity(0.55)))
        .offset(y: geometryOffset)
    }
}

/// Opens, positions and closes the bubble, and owns the preview-only session.
@MainActor
final class CameraBubbleController {

    private var panel: CameraBubblePanel?
    private var ownSession: AVCaptureSession?
    private var recordingSession: AVCaptureSession?
    private weak var state: AppState?

    var isShowing: Bool { panel != nil }

    func show(state: AppState) {
        self.state = state
        let d = state.settings.cameraSize.diameter

        if recordingSession == nil && ownSession == nil, let s = makePreviewSession() {
            ownSession = s
            // Off the main thread: startRunning blocks until the device is ready, which
            // is long enough to be seen as a hang.
            Task.detached { s.startRunning() }
        }

        let root = NSHostingView(rootView: CameraBubbleView(state: state,
                                                            session: recordingSession ?? ownSession))
        if let panel {
            panel.contentView = root
            panel.setDiameter(d)
            panel.orderFrontRegardless()
            return
        }
        let p = CameraBubblePanel(view: root, diameter: d)
        p.onMoved = { [weak self] centre, screen in self?.noteMoved(centre: centre, screen: screen) }
        p.moveToDefaultCorner()
        p.orderFrontRegardless()
        panel = p
        noteMoved(centre: CGPoint(x: p.frame.midX, y: p.frame.midY), screen: p.screen)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        stopOwnSession()
    }

    /// Swaps the bubble onto the recording's session when one starts, and back to its own
    /// when it stops, so it keeps showing a live picture either side of a take.
    func useSession(_ session: AVCaptureSession?) {
        recordingSession = session
        if session != nil { stopOwnSession() }
        guard let state, isShowing else { return }
        show(state: state)
    }

    /// The parking spot becomes the recording's corner. Recomputed on every move rather
    /// than read at the moment recording starts, so the setting is already right when
    /// the user hits record — and is visible in Settings before then.
    private func noteMoved(centre: CGPoint, screen: NSScreen?) {
        guard let state, let bounds = (screen ?? NSScreen.main)?.frame else { return }
        let corner = CameraOverlay.nearestCorner(to: centre, in: bounds)
        guard state.settings.cameraCorner != corner else { return }
        state.settings.cameraCorner = corner
    }

    private func makePreviewSession() -> AVCaptureSession? {
        guard CameraCapture.permission().canCapture,
              let device = CameraCapture.device(id: nil),
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        let s = AVCaptureSession()
        s.beginConfiguration()
        // A preview does not need recording quality, and asking for less keeps the camera
        // light while something else is doing the real work.
        s.sessionPreset = .medium
        if s.canAddInput(input) { s.addInput(input) }
        s.commitConfiguration()
        return s
    }

    private func stopOwnSession() {
        guard let s = ownSession else { return }
        ownSession = nil
        Task.detached { s.stopRunning() }
    }
}
