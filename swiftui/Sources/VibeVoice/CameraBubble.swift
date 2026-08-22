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
        guard !isMovingProgrammatically else { return }
        onMoved?(CGPoint(x: frame.midX, y: frame.midY), screen)
    }

    private var isMovingProgrammatically = false

    /// Moves without reporting it as a drag. See `CameraBubbleController.followDisplay`.
    func moveWithoutNotifying(to origin: CGPoint) {
        isMovingProgrammatically = true
        setFrameOrigin(origin)
        isMovingProgrammatically = false
    }
}

/// The live picture.
///
/// `AVCaptureVideoPreviewLayer` rather than drawing frames ourselves: it is hardware-fed,
/// costs almost nothing, and stays smooth while ScreenCaptureKit and the encoder are also
/// running — which is exactly when a hand-rolled preview would start dropping frames.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession?
    var mirrored: Bool = false
    /// Applied by AppKit, not by SwiftUI.
    ///
    /// `.clipShape` and `.shadow` do not reach inside an `NSViewRepresentable`: SwiftUI
    /// has no idea what the hosted view draws, so it clips nothing and casts the shadow
    /// of the full rectangle. What that looks like is a square of black backing and a
    /// square halo around a round bubble — which is exactly what it looked like.
    var shape: CameraShape = .circle

    final class View: NSView {
        private var preview: AVCaptureVideoPreviewLayer?
        private weak var attached: AVCaptureSession?

        private var shape: CameraShape = .circle

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            // The letterbox behind the video, and nothing outside the mask.
            layer?.backgroundColor = NSColor.black.cgColor
        }

        func setShape(_ next: CameraShape) {
            shape = next
            applyMask()
        }

        private func applyMask() {
            layer?.cornerRadius = min(bounds.width, bounds.height) * shape.cornerFraction
            layer?.cornerCurve = shape == .rounded ? .continuous : .circular
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        /// Mirroring is set on the preview connection, not by flipping the layer: a
        /// scaled layer transform also mirrors the border and the shadow drawn around it.
        func setMirrored(_ on: Bool) {
            guard let c = preview?.connection, c.isVideoMirroringSupported else { return }
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = on
        }

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
            applyMask()
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> View {
        let v = View()
        v.attach(session)
        v.setMirrored(mirrored)
        v.setShape(shape)
        return v
    }

    func updateNSView(_ v: View, context: Context) {
        v.attach(session)
        v.setMirrored(mirrored)
        v.setShape(shape)
    }
}

/// The bubble itself, with the controls that appear under the cursor.
///
/// Modelled on Loom's, because Loom's are right: the sizes are shown as dots that are
/// actually the relative sizes rather than as words, the selected one is filled, and the
/// name appears above the bar only while you are pointing at a button. Nothing is
/// labelled until you need the label, so the bar stays small enough to sit inside the
/// circle instead of widening the panel over whatever is being demonstrated.
struct CameraBubbleView: View {
    @ObservedObject var state: AppState
    var session: AVCaptureSession?

    @State private var hovering = false
    @State private var hoveredControl: String?

    private var size: CameraSize { state.settings.cameraSize }
    private var shape: CameraShape { state.settings.cameraShape }

    private var outline: AnyShape {
        switch shape {
        case .circle:  return AnyShape(Circle())
        case .rounded: return AnyShape(RoundedRectangle(cornerRadius: size.diameter * 0.18, style: .continuous))
        case .square:  return AnyShape(Rectangle())
        }
    }

    var body: some View {
        ZStack {
            CameraPreview(session: session,
                          mirrored: state.settings.cameraMirrored,
                          shape: shape)
                .overlay(outline.stroke(.white.opacity(0.22), lineWidth: 2))

            if size.isFullFrame {
                // A small preview cannot show what a full-frame recording will look
                // like, so it says so rather than implying the crop is the circle.
                pill("Full frame").offset(y: -size.diameter * 0.28)
            }

            if hovering && state.settings.cameraControls {
                VStack(spacing: 5) {
                    if let hoveredControl { pill(hoveredControl) }
                    controls
                }
                .offset(y: size.diameter * 0.26)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.10), value: hoveredControl)
        .onHover { hovering = $0; if !$0 { hoveredControl = nil } }
        // No shadow, and so no padding for one to land in: the panel is exactly the
        // bubble, and every point of it is picture.
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(.black.opacity(0.7)))
    }

    private var controls: some View {
        HStack(spacing: 2) {
            button("Turn off camera", systemImage: "xmark") {
                state.settings.cameraBubble = false
                state.applyCameraBubble()
            }
            // Dots sized in proportion to what they select — the size is the icon.
            ForEach([CameraSize.small, .medium, .large]) { s in
                button(s.label, selected: s == size) { state.setCameraSize(s) } content: {
                    Circle()
                        .fill(.white)
                        .frame(width: dot(for: s), height: dot(for: s))
                }
            }
            button("Full frame",
                   systemImage: "arrow.up.left.and.arrow.down.right",
                   selected: size == .full) { state.setCameraSize(.full) }
            button(shape == .circle ? "Rounded" : "Circle",
                   systemImage: shape == .circle ? "square" : "circle") {
                state.setCameraShape(shape == .circle ? .rounded : .circle)
            }
        }
        .padding(4)
        .background(Capsule().fill(.black.opacity(0.7)))
    }

    /// 6 / 9 / 12 points — small enough to read as "the little one" at a glance.
    private func dot(for s: CameraSize) -> CGFloat {
        switch s {
        case .small:  return 6
        case .medium: return 9
        default:      return 12
        }
    }

    private func button(_ name: String,
                        systemImage: String? = nil,
                        selected: Bool = false,
                        action: @escaping () -> Void,
                        @ViewBuilder content: () -> some View = { EmptyView() }) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(selected ? Color.accentColor : .white.opacity(0.001))
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    content()
                }
            }
            .frame(width: 20, height: 20)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredControl = $0 ? name : (hoveredControl == name ? nil : hoveredControl) }
        .accessibilityLabel(name)
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

    /// Moves the bubble to another screen, keeping the corner it was parked in.
    ///
    /// The corner is preserved rather than the coordinates: the two displays do not
    /// share a coordinate space in any useful way, and a bubble that reappears in the
    /// middle of the new screen — or worse, half off it — is one the user has to go and
    /// rescue every time they change screens. Which corner it is has already been
    /// worked out from where they dragged it.
    func followDisplay(_ id: CGDirectDisplayID) {
        guard let panel, let state else { return }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }) else { return }
        guard panel.screen !== screen else { return }

        let v = screen.visibleFrame
        let d = panel.frame.width
        let inset: CGFloat = 28
        let origin: CGPoint
        switch state.settings.cameraCorner {
        case .bottomLeading:  origin = CGPoint(x: v.minX + inset,     y: v.minY + inset)
        case .bottomTrailing: origin = CGPoint(x: v.maxX - d - inset, y: v.minY + inset)
        case .topLeading:     origin = CGPoint(x: v.minX + inset,     y: v.maxY - d - inset)
        case .topTrailing:    origin = CGPoint(x: v.maxX - d - inset, y: v.maxY - d - inset)
        }
        // Directly, not through `setFrameOrigin`'s hook: this move is a consequence of
        // the corner, so feeding it back in as a new observation would be circular.
        panel.moveWithoutNotifying(to: origin)
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
