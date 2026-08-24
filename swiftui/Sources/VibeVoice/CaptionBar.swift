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
/// rather than a wide empty bar. It sits above the Dock on the display being worked on,
/// and it never takes focus or a click — see `hitTest`.
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
        ignoresMouseEvents = true      // it is a caption, not a control
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
    func place(on screen: NSScreen?, size: CGSize) {
        guard let v = (screen ?? NSScreen.main)?.visibleFrame else { return }
        setContentSize(CGSize(width: min(size.width, v.width - 80), height: size.height))
        layoutIfNeeded()
        setFrameOrigin(CGPoint(x: (v.midX - frame.width / 2).rounded(), y: v.minY + 64))
    }
}

struct CaptionBarView: View {
    let line: CaptionState.Line

    private var tint: Color {
        // The assistant speaks in the app's own colour; the user is neutral. Two speakers
        // in one strip need telling apart at a glance, and a label saying which would be
        // longer than some of the captions.
        line.speaker == .assistant ? Theme.voice : Theme.textDim
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            Text(line.text)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background {
            // Dark and blurred rather than solid: it lies over arbitrary content, and a
            // flat panel would look pasted on top of a photograph.
            ZStack {
                VisualEffectBackground()
                Color.black.opacity(0.55)
            }
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
        .padding(10)   // room for the shadow inside the panel
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

    /// Which screen to appear on. Set from the active-display watcher, so captions follow
    /// the work like everything else does.
    var screen: NSScreen?

    func say(_ speaker: CaptionState.Speaker, _ text: String, done: Bool = false) {
        guard isEnabled else { return }
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
        let root = AnyView(CaptionBarView(line: line))

        if let host {
            host.rootView = root
        } else {
            let h = NSHostingView(rootView: root)
            host = h
            let p = CaptionPanel(view: h)
            panel = p
        }
        guard let panel, let host else { return }

        // Sized to the text rather than fixed: a two-word caption in a 520-point bar is
        // mostly empty box, and an empty box over somebody's screen is just clutter.
        let fitted = host.fittingSize
        panel.place(on: screen, size: CGSize(width: max(220, fitted.width),
                                             height: max(52, fitted.height)))
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }
}
