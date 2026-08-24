import SwiftUI
import AppKit
import VibeVoiceCore

/// Subtitles for the conversation, over whatever you are actually doing.
///
/// The app's own window is usually not in front — it is a voice assistant — so the
/// transcript scrolling inside it is invisible exactly when it is most wanted: when the
/// thing has misheard you and you cannot tell whether it is answering the wrong question.
///
/// Sized to its text and re-centred as it grows, so a two-word caption is a small pill
/// rather than a wide empty bar. It never takes focus or a click.
///
/// **It follows the active screen.** It sits above the Dock on whichever display the
/// pointer has settled on, moves mid-sentence when you do, and — with several displays
/// attached and no settled answer for which is active — shows nothing at all rather than
/// appearing on the wrong one. The rule is `ActiveScreenOverlay`; what makes a display
/// active is `ActiveDisplayGate`.
final class CaptionPanel: NSPanel {

    init(view: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 64),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Switched per caption — see `CaptionController.refresh`. A caption with nothing
        // hidden is click-through; one with more to read accepts a hover.
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Centres horizontally on the given screen, a comfortable distance above the Dock.
    ///
    /// Two steps, deliberately: the size is applied first and the position computed from
    /// the frame that results. Doing both from the hosting view's `fittingSize` in one go
    /// put the bar tens of points off centre, because the width AppKit settles on is not
    /// always the width that was asked for.
    ///
    /// The screen is required, not optional. It used to fall back to `NSScreen.main`,
    /// which is the screen holding the key window — FlowState's own — so before the
    /// pointer had ever settled anywhere the subtitles for what you are doing appeared on
    /// the display you are not doing it on. There is no honest fallback here: no active
    /// screen means no caption. See `ActiveScreenOverlay`.
    func place(on screen: NSScreen, size: CGSize) {
        let v = screen.visibleFrame
        setContentSize(CGSize(width: min(size.width, v.width - 80), height: size.height))
        layoutIfNeeded()
        setFrameOrigin(CGPoint(x: (v.midX - frame.width / 2).rounded(), y: v.minY + 64))
    }
}

struct CaptionBarView: View {
    let line: CaptionState.Line
    /// True when the text was cut down to fit. Only then is hovering worth anything, and
    /// only then does the panel take the mouse at all.
    var truncated: Bool = false

    @State private var expanded = false

    /// Called when the content changes shape, so the panel can grow to fit.
    ///
    /// Expanding on hover changes what SwiftUI draws but not what AppKit sized the window
    /// to, and a window that stays the old size simply clips the text that hovering was
    /// supposed to reveal.
    var onResize: (CGSize) -> Void = { _ in }

    /// Reduce Transparency, from the system. The blur below is the whole reason this
    /// strip does not look pasted onto a photograph — and it is also exactly what that
    /// setting exists to switch off, because translucent text over arbitrary desktop
    /// content is the hardest thing on screen to read.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var tint: Color {
        // The assistant speaks in the app's own colour; the user is neutral. Two speakers
        // in one strip need telling apart at a glance, and a label saying which would be
        // longer than some of the captions.
        line.speaker == .assistant ? Theme.voice : Theme.textDim
    }

    /// Who is talking, spelled out. The dot says it to everyone who can see the dot.
    private var speakerName: String {
        line.speaker == .assistant ? "Flow" : "You"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            Text(expanded ? line.full : line.text)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background {
            // Dark and blurred rather than solid: it lies over arbitrary content, and a
            // flat panel would look pasted on top of a photograph.
            //
            // Under Reduce Transparency it becomes near-opaque instead. That loses the
            // look and keeps the words, which is the right way round for a strip whose
            // entire job is being readable over content nobody chose.
            ZStack {
                if !reduceTransparency { VisualEffectBackground() }
                Color.black.opacity(reduceTransparency ? 0.96 : 0.55)
            }
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(.white.opacity(reduceTransparency ? 0.35 : 0.10), lineWidth: 1)
        }
        // The shadow needs more room than it was given: a blur of 18 offset by 6 reaches
        // 24 points below the box, and a 10-point margin cropped it into a hard line
        // across the bottom — a shadow with an edge looks worse than no shadow.
        .shadow(color: .black.opacity(0.38), radius: 14, y: 4)
        .padding(20)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.size) { _, new in onResize(new) }
                    .onAppear { onResize(geo.size) }
            }
        }
        .onHover { hovering in
            guard truncated else { return }
            withAnimation(.easeOut(duration: 0.14)) { expanded = hovering }
        }
        // The panel ignores the mouse, which makes it invisible to hit-testing — but not
        // a reason to make it invisible to VoiceOver. Someone using both a screen reader
        // and captions is not a hypothetical; the speaker is named because the coloured
        // dot that distinguishes them is not readable.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(speakerName) said")
        .accessibilityValue(line.text)
    }
}

/// Owns the panel, and the clock that decides when it goes away.
@MainActor
final class CaptionController {

    private var panel: CaptionPanel?
    private var host: NSHostingView<AnyView>?
    private var state = CaptionState()
    private var timer: Timer?

    var isEnabled = false {
        didSet { if !isEnabled { hide() } }
    }

    /// Which display to appear on — the active screen, resolved by `ActiveScreenOverlay`
    /// and fed from the active-display watcher, so captions follow the work like the
    /// camera bubble and the widget do.
    ///
    /// `nil` means "no active screen resolved", and the caption stays off. That is the
    /// point of storing an id rather than an `NSScreen`: nil is a real answer here, not a
    /// missing one to be papered over with `NSScreen.main`.
    private(set) var displayID: CGDirectDisplayID?

    /// The active screen, if it is still attached.
    private var screen: NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    /// Moves to another display, taking a caption that is already up along with it.
    ///
    /// Repositioning immediately rather than at the next line is the difference between
    /// following and lagging: an answer takes seconds to speak, and for all of them the
    /// old code left the subtitles on the screen you just walked away from.
    func followDisplay(_ id: CGDirectDisplayID?) {
        guard displayID != id else { return }
        displayID = id
        guard isEnabled else { return }
        // Nowhere to be. Off beats guessing — see `ActiveScreenOverlay`.
        guard id != nil else { return hide() }
        // Only if something is actually on screen; otherwise the next `say` places it.
        guard panel != nil, state.visible(at: Date()) else { return }
        refresh()
    }

    func say(_ speaker: CaptionState.Speaker, _ text: String, done: Bool = false) {
        guard isEnabled else { return }
        // Only its half of the conversation.
        //
        // Captioning the user's own words was the first version and it is the wrong
        // instinct: you know what you said, and seeing it repeated over your work is
        // noise. The reason for reading a caption at all is to follow what is being
        // said back to you.
        guard speaker == .assistant else { return }
        state.say(speaker, text, at: Date(), done: done)
        refresh()
        startClock()
    }

    func clear() {
        state.clear()
        hide()
    }

    private func startClock() {
        guard timer == nil else { return }
        // Quarter-second: the linger is measured in seconds, and a caption that hangs
        // around a fraction too long is not something anybody notices.
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.state.visible(at: Date()) {
                    self.hide()
                    self.timer?.invalidate()
                    self.timer = nil
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refresh() {
        guard let line = state.line else { return hide() }
        let root = AnyView(CaptionBarView(line: line, truncated: state.wasTruncated,
                                          onResize: { [weak self] size in
                                              self?.resize(to: size)
                                          }))

        if let host {
            host.rootView = root
        } else {
            let h = NSHostingView(rootView: root)
            host = h
            let p = CaptionPanel(view: h)
            panel = p
        }
        guard let panel, let host else { return }
        // Click-through unless there is something hidden to reveal. A strip that eats
        // clicks over the middle of somebody's screen is a nuisance; one that does so
        // only when it is holding back text they might want is a control.
        panel.ignoresMouseEvents = !state.wasTruncated
        // No active screen — the pointer has not settled on one of several displays, or
        // the one it had settled on has been unplugged. Say nothing anywhere rather than
        // saying it on the wrong screen.
        guard let screen else { return hide() }

        // Sized to the text rather than fixed: a two-word caption in a 520-point bar is
        // mostly empty box, and an empty box over somebody's screen is just clutter.
        let fitted = host.fittingSize
        panel.place(on: screen, size: CGSize(width: max(220, fitted.width),
                                             height: max(52, fitted.height)))
        panel.orderFrontRegardless()
    }

    /// The content changed shape — usually a hover expanding it. Re-place rather than
    /// only resize, so it stays centred as it grows.
    private func resize(to size: CGSize) {
        guard let panel, let screen, panel.isVisible else { return }
        panel.place(on: screen, size: CGSize(width: max(220, size.width),
                                             height: max(52, size.height)))
    }

    private func hide() {
        panel?.orderOut(nil)
    }
}
