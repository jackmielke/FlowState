import SwiftUI
import AppKit
import FlowStateCore

// MARK: - Position

/// Position for a pane that floats *over* the app instead of covering it.
///
/// A sheet is the wrong shape for Settings here: half of what the settings change —
/// backdrop, appearance, the orb, the transcript — is only judgeable while you can still
/// see it. So the pane stays inside the window, the app stays visible and live behind it,
/// and the user can shove the pane out of the way of whatever they are looking at.
///
/// The geometry itself lives in `PanelLayout`, where it is tested. What is left here is
/// the part that is genuinely stateful: where the user put it, and remembering that
/// between launches.
@MainActor
final class FloatingPanelController: ObservableObject {

    /// Where the user put it, in container coordinates (top-left of the pane).
    /// `nil` means "never moved" — the default spot is used and keeps being recomputed
    /// as the window resizes, which is what you want until someone expresses an opinion.
    @Published private var custom: CGPoint?

    /// The size the pane would like, before the window and the content get a say.
    let ideal: CGSize

    private let key: String

    init(ideal: CGSize, key: String) {
        self.ideal = ideal
        self.key = key
        self.custom = Self.load(key)
    }

    // MARK: Geometry
    //
    // Pure functions of the container size and the measured content on purpose: `body`
    // needs the frame on every layout pass, and computing it from published state there
    // would mean mutating state during a view update.

    func size(in container: CGSize, contentHeight: CGFloat? = nil) -> CGSize {
        PanelLayout.size(ideal: ideal, contentHeight: contentHeight, in: container)
    }

    func origin(in container: CGSize, contentHeight: CGFloat? = nil) -> CGPoint {
        let s = size(in: container, contentHeight: contentHeight)
        return PanelLayout.clamp(custom ?? PanelLayout.defaultOrigin(s, in: container),
                                 size: s, in: container)
    }

    func frame(in container: CGSize, contentHeight: CGFloat? = nil) -> CGRect {
        CGRect(origin: origin(in: container, contentHeight: contentHeight),
               size: size(in: container, contentHeight: contentHeight))
    }

    // MARK: Moving

    /// Commits a finished drag. The live translation is the view's business — see the
    /// note on `dragOffset` below — so this is called once, on release, and is the only
    /// thing that touches `@Published` state or the disk.
    func commitDrag(from anchor: CGPoint, translation: CGSize,
                    in container: CGSize, contentHeight: CGFloat? = nil) {
        custom = PanelLayout.dragged(from: anchor, by: translation,
                                     size: size(in: container, contentHeight: contentHeight),
                                     in: container)
        // Deliberately no snapping. Edge-and-centre snapping on release is what made this
        // feel glitchy: you let go and the pane jumps somewhere you did not put it. A
        // macOS window stays exactly where it is dropped. Clamping still applies, so it
        // cannot be lost off-screen — that is a safety net, not a magnet.
        save()
    }

    /// Nudge from the keyboard — the drag handle is focusable, so the pane can be moved
    /// without a mouse at all.
    func nudge(dx: CGFloat, dy: CGFloat, in container: CGSize, contentHeight: CGFloat? = nil) {
        let s = size(in: container, contentHeight: contentHeight)
        custom = PanelLayout.clamp(CGPoint(x: origin(in: container, contentHeight: contentHeight).x + dx,
                                           y: origin(in: container, contentHeight: contentHeight).y + dy),
                                   size: s, in: container)
        save()
    }

    /// Back to the default spot, and back to following it as the window resizes.
    func resetPosition() {
        custom = nil
        UserDefaults.standard.removeObject(forKey: key)
    }

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

// MARK: - Content height

/// How tall the pane's contents would like it to be.
///
/// Reported up rather than asked for down, because the content is inside a scroll view:
/// the scroll view will accept any height offered, so the only honest source of "what
/// does this actually need" is the content measuring itself. That measurement does not
/// depend on the pane's height, which is what keeps this from becoming a feedback loop.
///
/// Summed, not maxed, so a pane assembled from stacked pieces — a title bar, a tab strip,
/// a page — is measured by having each piece report itself. Every constant that used to
/// stand in for one of those was a guess that went stale the first time a font or a
/// padding changed, and a stale one leaves the pane a few points short with a scroll bar
/// it does not need.
struct PanelContentHeight: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        guard let next = nextValue() else { return }
        value = (value ?? 0) + next
    }
}

extension View {
    /// Measures this view and adds its natural height to what the surrounding
    /// `FloatingPanel` sizes itself to.
    func measuresPanelContent() -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: PanelContentHeight.self, value: g.size.height)
        })
    }
}

// MARK: - The panel

/// A floating, draggable pane pinned inside the app window.
///
/// Deliberately *not* a `.sheet`: no dimming layer, no blocked window. The app behind
/// stays visible and stays live. What says "this is the thing you are using right now"
/// is the pane itself — a real shadow lifting it off the app, and a title bar you can
/// grab.
struct FloatingPanel<Content: View>: View {
    let title: String
    @Binding var isPresented: Bool
    @StateObject private var panel: FloatingPanelController
    private let content: () -> Content

    /// The last height the content asked for. Nil until it has been measured once, which
    /// is the one frame the pane stands at its full ideal height.
    @State private var contentHeight: CGFloat?

    /// Live drag, in points, relative to where the pane was when the drag began.
    ///
    /// Local to the view and applied as an offset rather than pushed into the controller
    /// on every pointer move. Two reasons, both of which were visible before: publishing
    /// at pointer rate re-ran the whole settings body for every pixel of movement, and
    /// writing the position to `UserDefaults` mid-drag did disk I/O in the same breath.
    @State private var dragOffset: CGSize = .zero
    @State private var dragAnchor: CGPoint?

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

    private static var settle: Animation { .spring(response: 0.30, dampingFraction: 0.86) }
    /// Resizing between tabs. Slightly slower and completely un-bouncy: a pane that
    /// overshoots its new height reads as a wobble, not as polish.
    private static var resize: Animation { .spring(response: 0.34, dampingFraction: 1.0) }

    var body: some View {
        // A GeometryReader with nothing but the pane in it hit-tests only where the pane
        // is, which is what leaves the app behind it clickable.
        GeometryReader { geo in
            if isPresented {
                let f = panel.frame(in: geo.size, contentHeight: contentHeight)
                pane(in: geo.size)
                    .frame(width: f.width, height: f.height)
                    .position(x: f.midX, y: f.midY)
                    // The drag rides on top of the settled position. Nothing else in the
                    // layout moves while it changes, so a drag costs one transform.
                    .offset(dragOffset)
                    .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
                    // Height changes are animated; the position changes that follow from
                    // them (a taller pane pushed up off the bottom edge) come along with
                    // it, because both are read from the same frame.
                    .animation(Self.resize, value: contentHeight)
                    .onPreferenceChange(PanelContentHeight.self) { h in
                        guard let h,
                              let settled = PanelLayout.settledHeight(h, current: contentHeight)
                        else { return }
                        contentHeight = settled
                    }
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isPresented)
    }

    private func pane(in container: CGSize) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                PanelGrabBar(
                    title: title,
                    onClose: { close() },
                    onReset: { withAnimation(Self.settle) { panel.resetPosition() } },
                    onNudge: { dx, dy in
                        withAnimation(.easeOut(duration: 0.12)) {
                            panel.nudge(dx: dx, dy: dy, in: container, contentHeight: contentHeight)
                        }
                    })
                    // High priority so the grab bar wins over anything the content puts
                    // under it, but scoped to the bar — the settings body itself is not
                    // draggable, or every slider would move the window instead.
                    //
                    // `.global` is load-bearing. In `.local` the coordinate space travels
                    // with the pane, so each point of movement cancelled a point of
                    // translation: the pane crawled at half the pointer's speed and
                    // jittered whenever the two disagreed. Global space does not move.
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in drag(v.translation, in: container) }
                            .onEnded { v in endDrag(v.translation, in: container) })

                Divider().overlay(Theme.hairline)
            }
            // The title bar is part of what the pane has to be tall enough for.
            .measuresPanelContent()

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // A single hairline, the same one used everywhere else in the app. It used to be
        // an accent ring, which is the "blue perimeter" problem in a warmer colour: a
        // border that shouts is a border you notice instead of the content.
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))
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

    // MARK: Dragging

    private func drag(_ translation: CGSize, in container: CGSize) {
        let anchor = dragAnchor ?? panel.origin(in: container, contentHeight: contentHeight)
        dragAnchor = anchor
        // Clamped live, so the pane stops dead at the window edge instead of following
        // the pointer out and snapping back on release.
        let landed = PanelLayout.dragged(from: anchor, by: translation,
                                         size: panel.size(in: container, contentHeight: contentHeight),
                                         in: container)
        dragOffset = CGSize(width: landed.x - anchor.x, height: landed.y - anchor.y)
    }

    private func endDrag(_ translation: CGSize, in container: CGSize) {
        guard let anchor = dragAnchor else { return }
        // Committed and zeroed in the same update: the settled frame and the offset it
        // replaces have to change together, or the pane flickers back to where it started
        // for one frame. No animation — the pane is already under the cursor, and
        // animating "to" where it already is only adds visible lag.
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            panel.commitDrag(from: anchor, translation: translation,
                             in: container, contentHeight: contentHeight)
            dragOffset = .zero
            dragAnchor = nil
        }
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
        // Keyboard focus, said quietly: a two-point bar under the title rather than the
        // system's blue rectangle around it. Still unmistakable when you tab to it, and
        // it does not put a coloured perimeter on the pane the rest of the time.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.accent)
                .frame(height: 2)
                .opacity(focused ? 0.9 : 0)
                .padding(.horizontal, 12)
                .animation(.easeOut(duration: 0.14), value: focused)
        }
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
        .focusEffectDisabled()
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
