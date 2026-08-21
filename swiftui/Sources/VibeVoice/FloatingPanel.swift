import SwiftUI
import AppKit

// MARK: - Position

/// Position and size for a pane that floats *over* the app instead of covering it.
///
/// A sheet is the wrong shape for Settings here: half of what the settings change —
/// backdrop, appearance, the orb, the transcript — is only judgeable while you can still
/// see it. So the pane stays inside the window, the app stays visible and live behind it,
/// and the user can shove the pane out of the way of whatever they are looking at.
///
/// The rules below are what keeps that from becoming a mess: never bigger than the window
/// it floats in, never draggable off the edge, and lined up with an edge or the centre
/// line when it is dropped near one.
@MainActor
final class FloatingPanelController: ObservableObject {

    /// Where the user put it, in container coordinates (top-left of the pane).
    /// `nil` means "never moved" — the default spot is used and keeps being recomputed
    /// as the window resizes, which is what you want until someone expresses an opinion.
    @Published private var custom: CGPoint?
    @Published private(set) var isDragging = false

    /// The size the pane would like, before the window gets a say.
    let ideal: CGSize

    private let key: String
    /// Breathing room kept between the pane and the window edge.
    private let margin: CGFloat = 14
    /// How near an edge — or the centre line — counts as meaning to line up with it.
    /// Top-left the drag started from. A drag has to be measured from where the pane
    /// *was*, not from wherever the pointer happens to be, or clamping at one edge
    /// would make the pane jump when the pointer comes back.
    private var dragAnchor: CGPoint?

    init(ideal: CGSize, key: String) {
        self.ideal = ideal
        self.key = key
        self.custom = Self.load(key)
    }

    // MARK: Geometry
    //
    // Pure functions of the container size on purpose: `body` needs the frame on every
    // layout pass, and computing it from published state there would mean mutating state
    // during a view update.

    func size(in container: CGSize) -> CGSize {
        CGSize(width:  min(ideal.width,  max(260, container.width  - margin * 2)),
               height: min(ideal.height, max(220, container.height - margin * 2)))
    }

    func frame(in container: CGSize) -> CGRect {
        let s = size(in: container)
        return CGRect(origin: clamp(custom ?? defaultOrigin(s, in: container), s, in: container),
                      size: s)
    }

    /// Where an unmoved pane sits: centred across, tucked just under the app's own
    /// header, which is roughly where a sheet used to drop from.
    private func defaultOrigin(_ s: CGSize, in container: CGSize) -> CGPoint {
        CGPoint(x: (container.width - s.width) / 2, y: 64)
    }

    /// The whole "not off-screen" guarantee, in one place.
    private func clamp(_ p: CGPoint, _ s: CGSize, in container: CGSize) -> CGPoint {
        CGPoint(x: min(max(p.x, margin), max(margin, container.width  - s.width  - margin)),
                y: min(max(p.y, margin), max(margin, container.height - s.height - margin)))
    }

    // MARK: Dragging

    func dragChanged(_ translation: CGSize, in container: CGSize) {
        let anchor = dragAnchor ?? frame(in: container).origin
        dragAnchor = anchor
        isDragging = true
        custom = clamp(CGPoint(x: anchor.x + translation.width,
                               y: anchor.y + translation.height),
                       size(in: container), in: container)
    }

    func dragEnded(_ translation: CGSize, in container: CGSize) {
        dragChanged(translation, in: container)
        dragAnchor = nil
        isDragging = false
        // Deliberately no snapping. Edge-and-centre snapping on release is what made
        // this feel glitchy: you let go and the pane jumps somewhere you did not put it.
        // A macOS window stays exactly where it is dropped, and that is the whole
        // expectation being matched here. Clamping still applies, so it cannot be lost
        // off-screen — that is a safety net, not a magnet.
        save()
    }

    /// Nudge from the keyboard — the drag handle is focusable, so the pane can be moved
    /// without a mouse at all.
    func nudge(dx: CGFloat, dy: CGFloat, in container: CGSize) {
        let o = frame(in: container).origin
        custom = clamp(CGPoint(x: o.x + dx, y: o.y + dy), size(in: container), in: container)
        save()
    }

    /// Back to the default spot, and back to following it as the window resizes.
    func resetPosition() {
        custom = nil
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Dropped near an edge or the centre line, the pane lines up with it. Only the axis
    /// that is actually close is affected, so a pane dropped against the left edge keeps
    /// whatever height the user chose.

    // MARK: Persistence
    //
    // Stored raw rather than as a fraction of the window: `clamp` already rescues a
    // position that no longer fits, and a fraction would drift the pane away from the
    // edge it was deliberately parked against when the window is resized.

    private func save() {
        guard let p = custom else { return }
        UserDefaults.standard.set([p.x, p.y], forKey: key)
    }

    private static func load(_ key: String) -> CGPoint? {
        guard let v = UserDefaults.standard.array(forKey: key) as? [Double], v.count == 2
        else { return nil }
        return CGPoint(x: v[0], y: v[1])
    }
}

// MARK: - The panel

/// A floating, draggable pane pinned inside the app window.
///
/// Deliberately *not* a `.sheet`: no dimming layer, no blocked window. The app behind
/// stays visible and stays live. What says "this is the thing you are using right now"
/// is the pane itself — an accent ring, a real shadow lifting it off the app, and a
/// title bar you can grab.
struct FloatingPanel<Content: View>: View {
    let title: String
    @Binding var isPresented: Bool
    @StateObject private var panel: FloatingPanelController
    private let content: () -> Content

    init(title: String,
         isPresented: Binding<Bool>,
         ideal: CGSize,
         key: String,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._isPresented = isPresented
        self._panel = StateObject(wrappedValue: FloatingPanelController(ideal: ideal, key: key))
        self.content = content
    }

    private static var settle: Animation { .spring(response: 0.30, dampingFraction: 0.82) }

    var body: some View {
        // A GeometryReader with nothing but the pane in it hit-tests only where the pane
        // is, which is what leaves the app behind it clickable.
        GeometryReader { geo in
            if isPresented {
                let f = panel.frame(in: geo.size)
                pane(in: geo.size)
                    .frame(width: f.width, height: f.height)
                    .position(x: f.midX, y: f.midY)
                    .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isPresented)
    }

    private func pane(in container: CGSize) -> some View {
        VStack(spacing: 0) {
            PanelGrabBar(
                title: title,
                isDragging: panel.isDragging,
                onClose: { close() },
                onReset: { withAnimation(Self.settle) { panel.resetPosition() } },
                onNudge: { dx, dy in
                    withAnimation(.easeOut(duration: 0.12)) {
                        panel.nudge(dx: dx, dy: dy, in: container)
                    }
                })
                // High priority so the grab bar wins over anything the content puts
                // under it, but scoped to the bar — the settings body itself is not
                // draggable, or every slider would move the window instead.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { panel.dragChanged($0.translation, in: container) }
                        .onEnded { v in
                            // Not animated: the pane is already under the cursor, so
                            // animating "to" that spot only adds visible lag.
                            panel.dragEnded(v.translation, in: container)
                        })

            Divider().overlay(Theme.hairline)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1))
        // Two shadows: one that lifts the pane off the app, one accent-tinted glow that
        // does the job the dimming layer used to do — it marks the pane as the active
        // thing without taking the app behind it away.
        // One steady shadow. It used to grow and gain an accent glow mid-drag, which is
        // motion nobody asked for on top of the motion they did.
        .shadow(color: Theme.shadow, radius: 26, y: 12)
        // The window is movable by its background; without this, dragging the pane would
        // drag the whole window out from under it.
        .background(WindowDragBlocker())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) panel")
        .accessibilityAddTraits(.isModal)
        .onExitCommand { close() }
    }

    private func close() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { isPresented = false }
    }
}

// MARK: - Grab bar

/// The pane's title bar, and the only part of it that drags.
///
/// Deliberately plain, like a macOS title bar: a title, a close button, and the whole bar
/// draggable. It used to carry six grip dots and a tinted bar of its own to advertise that
/// it moved — but a title bar is already the most learned affordance on the platform, and
/// decorating it made the pane look like a widget rather than a window. The hand cursor on
/// hover says the same thing without adding furniture.
private struct PanelGrabBar: View {
    let title: String
    let isDragging: Bool
    var onClose: () -> Void
    var onReset: () -> Void
    var onNudge: (CGFloat, CGFloat) -> Void

    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle())
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close \(title.lowercased())")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        // The whole bar drags, including the gaps between things.
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Theme.accent, lineWidth: focused ? 2 : 0)
                .padding(1))
        .onTapGesture(count: 2) { onReset() }
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            if hovering { NSCursor.pop(); hovering = false }
        }
        .focusable()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            let step: CGFloat = press.modifiers.contains(.shift) ? 40 : 8
            switch press.key {
            case .leftArrow:  onNudge(-step, 0)
            case .rightArrow: onNudge(step, 0)
            case .upArrow:    onNudge(0, -step)
            default:          onNudge(0, step)
            }
            return .handled
        }
        .onKeyPress(.return) { onReset(); return .handled }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), drag handle")
        .accessibilityHint("Arrow keys move the panel. Return puts it back where it started.")
        .accessibilityAddTraits(.isHeader)
        .accessibilityAction(named: "Reset position") { onReset() }
    }

}

// MARK: - AppKit glue

/// Opts a subtree out of `isMovableByWindowBackground`.
///
/// The main window is draggable by its background, which is what makes the header work
/// as a title bar. Inside a floating pane that is exactly wrong: the drag has to move the
/// pane, not the window.
private struct WindowDragBlocker: NSViewRepresentable {
    final class Blocker: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
    func makeNSView(context: Context) -> NSView { Blocker() }
    func updateNSView(_ v: NSView, context: Context) {}
}

extension View {
    /// Presents `content` as a draggable pane floating over this view, in place of a
    /// sheet. The app behind stays visible, live and clickable.
    func floatingPanel<C: View>(_ title: String,
                                isPresented: Binding<Bool>,
                                ideal: CGSize,
                                key: String,
                                @ViewBuilder content: @escaping () -> C) -> some View {
        overlay(FloatingPanel(title: title,
                              isPresented: isPresented,
                              ideal: ideal,
                              key: key,
                              content: content))
    }
}
