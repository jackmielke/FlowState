import AppKit
import SwiftUI
import FlowStateCore

/// How much the floating widget shows.
///
/// The point of the smallest one is that it is ignorable: something that sits over your
/// work all day has to be able to say almost nothing. The largest is for a demo, where
/// the audience needs to see that it heard you and what it cost.
enum HUDStyle: String, Codable, CaseIterable, Identifiable {
    case orb, pill, bar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .orb:  return "Orb"
        case .pill: return "Pill"
        case .bar:  return "Bar"
        }
    }

    var blurb: String {
        switch self {
        case .orb:  return "Just the orb. Smallest thing that still shows it is listening."
        case .pill: return "Orb, state, mute and running cost."
        case .bar:  return "Everything, plus mute, connect and screenshot."
        }
    }

    /// The panel's size. Unchanged, because it is what the window is positioned by — the
    /// *drawn* widget is `surface`, a few points smaller, and the difference is a
    /// transparent margin the glow can spill into instead of being clipped at the edge.
    /// How much transparent room the glow gets on every side.
    ///
    /// `glowRadius` is about 13 points at its widest and the shadow reaches past that,
    /// where the old margin was six — so the glow was clipped square at the corners. The
    /// margin is click-through (see `HUDContainerView`), so paying for it costs nothing
    /// but pixels nobody can see.
    static let glowMargin: CGFloat = 26

    var size: CGSize {
        CGSize(width: surface.width + Self.glowMargin * 2,
               height: surface.height + Self.glowMargin * 2)
    }


    /// The area the widget owns: what it draws on in the text styles, and in the orb
    /// style what you can click and drag even though nothing is painted there. Slightly
    /// smaller than it used to be: with the perimeter stroke gone there is nothing
    /// holding the extra width, and a solid black shape reads heavier than a translucent
    /// one at the same size.
    var surface: CGSize {
        switch self {
        case .orb:  return CGSize(width: 66,  height: 66)
        case .pill: return CGSize(width: 232, height: 54)
        case .bar:  return CGSize(width: 344, height: 54)
        }
    }

    /// Whether anything is painted on that area. Only the styles with text need a plate
    /// to carry it; the orb is legible on its own, and a black disc behind it is a
    /// perimeter with nothing to do but ring the thing you were looking at.
    var showsSurface: Bool { self != .orb }

    var corner: CGFloat { self == .orb ? 33 : 15 }

    var orbDiameter: CGFloat { self == .orb ? 50 : 36 }
}

/// The widget itself.
///
/// Everything here is deliberately quiet: no borders that pulse, no state that animates
/// on a timer. The orb already reacts to real audio, and that is the only motion a thing
/// living on top of someone's desktop has earned.
///
/// The surface is flat black with no perimeter at all, and in the orb style there is no
/// surface either — just the orb, over the desktop. That is the whole visual idea: the
/// shape is the shape, with nothing ringing it. The window's own shadow is off for the
/// same reason (see `HUDPanel`). Active state is carried by the orb and, where there is
/// a plate to light, by a soft coloured glow under it — never by chrome appearing,
/// pulsing or disappearing around the edge.
struct HUDView: View {
    @ObservedObject var state: AppState
    @State private var hovering = false
    /// Where the window was when the current drag began. Nil between drags.
    @State private var dragOrigin: CGPoint?
    /// The one case that earns a visible outline: someone who cannot rely on the orb's
    /// colour to tell live from idle.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// What the widget is currently drawn as.
    ///
    /// Hovering the smallest style promotes it one step, so the thing you leave up all
    /// day can stay a dot and still answer "is it listening, and what has it cost" the
    /// moment you look at it. The setting is the resting style; this is the shown one.
    private var style: HUDStyle {
        let resting = state.settings.hudStyle
        guard resting == .orb, hovering, state.settings.hudHoverExpand else { return resting }
        return .pill
    }

    /// The panel this view is drawn in. Looked up rather than injected: the view is built
    /// inside HUDPanel's own init, so there is no window to hand it at that point.

    /// The dictation badge.
    ///
    /// Pulled out of `body` because the view expression grew past what the type checker
    /// will attempt — "unable to type-check this expression in reasonable time", which is
    /// SwiftUI's way of saying one modifier too many.
    @ViewBuilder
    private var dictationBadge: some View {
                switch state.dictation.indicator {
                case .off:
                    EmptyView()
                case .listening:
                    Image(systemName: "waveform")
                        .font(.system(size: style == .orb ? 11 : 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(Theme.good))
                        .offset(x: 2, y: -2)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("Dictating")
                case .working:
                    Image(systemName: "ellipsis")
                        .font(.system(size: style == .orb ? 11 : 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(Theme.textFaint))
                        .offset(x: 2, y: -2)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("Transcribing")
                }
    }


    /// The two lines of text: what it is doing, and what it has cost.
    @ViewBuilder
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(statusLine)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isActive ? glow : Theme.text)
                .lineLimit(1)
            if state.cost.turns > 0 {
                Text("$" + state.cost.formatted)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
            } else {
                Text(subCaption)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    /// Mute, in every style with room for a button at all, and the first of them. On a
    /// widget that lives over someone's desktop all day it is the control most likely to
    /// be wanted in a hurry — someone has just walked in — so it does not get to be the
    /// one you have to aim for.
    private var muteButton: some View {
        Button { state.toggleMicMute() } label: {
            Image(systemName: MicMute.symbol(muted: state.isMicMuted))
        }
        .buttonStyle(HUDIconButtonStyle(on: state.isMicMuted))
        .help(MicMute.help(muted: state.isMicMuted, live: state.connection == .live))
        .accessibilityLabel(MicMute.label(muted: state.isMicMuted))
    }

    /// Connect and screenshot, in the widest style only.
    private var barButtons: some View {
        HStack(spacing: 6) {
            Button { state.toggleConnection() } label: {
                Image(systemName: state.connection == .live ? "stop.fill" : "waveform")
            }
            .buttonStyle(HUDIconButtonStyle())
            .help(state.connection == .live ? "End the session" : "Start a session")

            Button { Task { await state.captureAndSend(auto: false) } } label: {
                Image(systemName: "rectangle.dashed.badge.record")
            }
            .buttonStyle(HUDIconButtonStyle())
            .disabled(state.connection != .live)
            .help("Show it my screen")
        }
    }


    /// The widget's contents, before any of the chrome that positions and lights it.
    ///
    /// Separated from `body` so the modifier chain below applies to one opaque view
    /// rather than to a freshly inferred stack type: together they exceeded what the
    /// type checker will attempt.
    private var row: some View {
        HStack(spacing: style == .orb ? 0 : 11) {
            VoiceOrb(mode: mode, level: level)
                .frame(width: style.orbDiameter, height: style.orbDiameter)
                // In the smallest style there is no room for a button, so the state has
                // to ride on the orb itself. A slashed mic in the corner is the same
                // glyph the button carries, at the size the widget can afford.
                .overlay(alignment: .bottomTrailing) {
                    if state.isMicMuted {
                        Image(systemName: "mic.slash.fill")
                            .font(.system(size: style == .orb ? 11 : 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Circle().fill(Theme.bad))
                            .offset(x: 2, y: 2)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                // Dictation rides the opposite corner from mute, and uses a waveform
                // rather than a mic glyph, because the one thing this badge must never do
                // is read as "muted" or as a live session. Different corner, different
                // shape, different colour — three signals, since at 11 points any one of
                // them alone is easy to misread at a glance.
                .overlay(alignment: .topTrailing) { dictationBadge }
                .animation(.easeOut(duration: 0.16), value: state.dictation.indicator)
                .contentShape(Circle())
                .help(isActive ? "Click to end · drag to move" : "Click to start · drag to move")
                .animation(.easeOut(duration: 0.16), value: state.isMicMuted)

            if style != .orb { statusBlock }

            // Mute is in every style that has room for a button at all, and it is the
            // FIRST of them. On a widget that lives over someone's desktop all day it is
            // the control most likely to be wanted in a hurry — someone has just walked
            // in — so it does not get to be the one you have to aim for.
            if style != .orb { muteButton }
            if style == .bar { barButtons }
        }
    }


    /// The orb style's only route to the controls, and a right-click away in the others.
    @ViewBuilder
    private var menu: some View {
        Button(MicMute.label(muted: !state.isMicMuted)) { state.toggleMicMute() }
        Button(isActive ? "End session" : "Start session") { state.toggleConnection() }
        Divider()
        Menu("Tuck away") {
            Button("For 5 minutes")  { tuckAway(minutes: 5) }
            Button("For 15 minutes") { tuckAway(minutes: 15) }
            Button("For an hour")    { tuckAway(minutes: 60) }
            Button("Until I bring it back") { tuckAway(minutes: nil) }
        }
        Button("Open FlowState") { Summon.toggle() }
    }


    /// The widget as drawn and driven — everything except the menu and the
    /// accessibility surface, which are the two heaviest parts of the chain for the type
    /// checker and the two that do not affect a single pixel.
    private var plate: some View {
        row
        .padding(.horizontal, style == .orb ? 8 : 13)
        .padding(.vertical, 8)
        .frame(width: style.surface.width, height: style.surface.height)
        .background {
            if style.showsSurface {
                RoundedRectangle(cornerRadius: style.corner, style: .continuous)
                    .fill(Color.black)
            }
        }
        // Not a border: the glow sits *under* the black surface and bleeds past it, so it
        // reads as the widget being lit from inside rather than as chrome switching on.
        .shadow(color: glow.opacity(showsGlow ? 0.55 : 0), radius: glowRadius)
        .overlay(
            // Colour-independent proof of life, drawn only when the system asks for it.
            RoundedRectangle(cornerRadius: style.corner, style: .continuous)
                .strokeBorder(Color.white.opacity(differentiateWithoutColor && isActive ? 0.85 : 0),
                              lineWidth: 1.5)
        )
        // One gesture, both jobs — see `moveOrClick`.
        .contentShape(RoundedRectangle(cornerRadius: style.corner, style: .continuous))
        .gesture(moveOrClick)
        .opacity(hovering ? 1 : state.settings.hudIdleOpacity)
        .onHover { hovering = $0 }
        // The window resizes too, not just the drawing: the panel is only as big as the
        // resting style, so a pill drawn inside an orb-sized window has its ends cut off.
        .onChange(of: style) { _, now in hudWindow?.resize(to: now, animate: true) }
        // The transparent remainder of the panel: room for the glow to spill into.
        .frame(width: style.size.width, height: style.size.height)
        .animation(.easeOut(duration: 0.18), value: isActive)
    }

    private var hudWindow: HUDPanel? { NSApp.windows.compactMap { $0 as? HUDPanel }.first }

    /// Move the widget, or start a session — decided by how far the pointer travelled.
    ///
    /// This used to lean on AppKit's isMovableByWindowBackground, with the orb taking
    /// clicks and "the rest of the surface" taking drags. In the orb style there is no
    /// rest: the orb is drawn across all 66 points of it, so its tap gesture swallowed
    /// every event and the small widget — the one you actually leave up all day — was the
    /// only one that could not be moved. Giving the orb a margin to grab by would work
    /// and would look like a mistake: a ring of dead space around a circle.
    private var moveOrClick: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { g in
                guard let win = hudWindow else { return }
                let anchor = dragOrigin ?? win.frame.origin
                if dragOrigin == nil { dragOrigin = anchor }
                // Below the slop this may still be a click, and shifting the window a
                // point or two under someone's finger reads as jitter.
                guard !HUDDrag.isClick(translation: g.translation) else { return }
                win.setFrameOrigin(HUDDrag.origin(from: anchor, translation: g.translation))
            }
            .onEnded { g in
                dragOrigin = nil
                if HUDDrag.isClick(translation: g.translation) {
                    state.toggleConnection()
                    return
                }
                guard let win = hudWindow,
                      let visible = (win.screen ?? NSScreen.main)?.visibleFrame else { return }
                // Tuckable half off the edge on purpose, never draggable somewhere it
                // cannot be got back from.
                let settled = HUDDrag.clamped(win.frame.origin, size: win.frame.size,
                                              in: visible, bleed: win.frame.width / 2)
                if settled != win.frame.origin { win.setFrameOrigin(settled) }
            }
    }

    /// Puts the widget away, with an end to it.
    ///
    /// A plain hide becomes a widget somebody switched off during a meeting three weeks
    /// ago and has been meaning to turn back on.
    private func tuckAway(minutes: Int?) {
        state.settings.hudHiddenUntil = minutes.map {
            Date().addingTimeInterval(TimeInterval($0) * 60)
        }
        if minutes == nil { state.settings.hudEnabled = false }
    }

    private var mode: OrbMode {
        switch state.connection {
        case .error:      return .error
        case .connecting: return .connecting
        case .idle:       return .idle
        case .live:
            // Speaking still wins over muted: the model's half of the conversation is
            // unaffected by the gate, and an orb that went inert while it talked would
            // be lying about the more interesting of the two.
            if state.audio.outLevel > 0.004 { return .speaking }
            if state.isMicMuted { return .muted }
            if state.userSpeaking || state.audio.micLevel > 0.012 { return .listening }
            return .idle
        }
    }

    private var level: Float { max(state.audio.micLevel, state.audio.outLevel * 1.15) }

    /// Live *or* connecting. Connecting counts: the tap has already been accepted, and a
    /// widget that stays dead-looking until the socket opens reads as a click that missed.
    private var isActive: Bool {
        switch state.connection {
        case .live, .connecting: return true
        case .idle, .error:      return false
        }
    }

    private var isError: Bool {
        if case .error = state.connection { return true }
        return false
    }

    /// Idle is the one state with no glow — the widget goes completely inert. Neither is
    /// there anything to light in the orb style: the glow exists to make the black plate
    /// look lit from inside, and with no plate it is just a coloured ring in mid-air.
    private var showsGlow: Bool { (isActive || isError) && style.showsSurface }

    /// What the glow is tinted with. Follows the orb so the two never disagree.
    private var glow: Color {
        switch state.connection {
        case .live:
            if mode == .speaking { return Theme.voice }
            // A muted session is live but not listening, and the glow is the only thing
            // on a 66-point widget big enough to say so from across the room.
            return state.isMicMuted ? Theme.bad : Theme.accent
        case .connecting: return Theme.textDim
        case .error:      return Theme.bad
        case .idle:       return .clear
        }
    }

    /// Fixed per state rather than per frame. Driving it from the level made the lit
    /// edge swell and drop back on every syllable, which at this size does not read as
    /// the surface breathing — it reads as a ring around the widget bouncing. The orb is
    /// already showing the amplitude; the perimeter does not need to say it again.
    private var glowRadius: CGFloat {
        guard showsGlow else { return 0 }
        return hovering ? 13 : 10
    }

    var body: some View {
        plate
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("FlowState")
        .accessibilityValue(statusLine)
        .accessibilityHint(isActive ? "Ends the voice session" : "Starts a voice session")
        .accessibilityAction { state.toggleConnection() }
        .accessibilityAction(named: MicMute.label(muted: !state.isMicMuted)) { state.toggleMicMute() }
        .accessibilityAction(named: "Open FlowState") { Summon.toggle() }
    }

    private var subCaption: String {
        if state.isMicMuted { return "mic off" }
        return isActive ? "listening" : "click the orb to start"
    }

    private var statusLine: String {
        switch state.connection {
        case .idle:       return "FlowState"
        case .connecting: return "Connecting…"
        case .error:      return "Needs attention"
        case .live:
            if state.devTaskRunning { return "Working…" }
            if mode == .speaking { return "Speaking" }
            // Ahead of "Listening", because it is the correction to it.
            if state.isMicMuted { return "Muted" }
            if state.userSpeaking { return "Listening" }
            return "Live"
        }
    }
}

/// The app-wide `IconButtonStyle` resolves its colours against the current appearance,
/// which on a surface that is black in *both* appearances paints dark-on-black in light
/// mode. These values are fixed to the surface, not to the system.
private struct HUDIconButtonStyle: ButtonStyle {
    /// Latched on — the button is not an action you took, it is a state you are in.
    /// Only mute uses it, and only mute should: a filled red key on a black surface is
    /// loud, which is the point when the thing it reports is "you cannot be heard".
    var on = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(on ? Color.white : Color.white.opacity(0.72))
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(on ? Theme.bad.opacity(configuration.isPressed ? 0.7 : 0.85)
                             : Color.white.opacity(configuration.isPressed ? 0.16 : 0.07))
            )
            .contentShape(Rectangle())
    }
}
