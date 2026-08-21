import SwiftUI

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
        case .pill: return "Orb, state and running cost."
        case .bar:  return "Everything, plus connect and screenshot."
        }
    }

    var size: CGSize {
        switch self {
        case .orb:  return CGSize(width: 78,  height: 78)
        case .pill: return CGSize(width: 208, height: 62)
        case .bar:  return CGSize(width: 320, height: 62)
        }
    }
}

/// The widget itself.
///
/// Everything here is deliberately quiet: no borders that pulse, no state that animates
/// on a timer. The orb already reacts to real audio, and that is the only motion a thing
/// living on top of someone's desktop has earned.
struct HUDView: View {
    @ObservedObject var state: AppState
    @State private var hovering = false

    private var style: HUDStyle { state.settings.hudStyle }

    private var mode: OrbMode {
        switch state.connection {
        case .error:      return .error
        case .connecting: return .connecting
        case .idle:       return .idle
        case .live:
            if state.audio.outLevel > 0.004 { return .speaking }
            if state.userSpeaking || state.audio.micLevel > 0.012 { return .listening }
            return .idle
        }
    }

    private var level: Float { max(state.audio.micLevel, state.audio.outLevel * 1.15) }

    var body: some View {
        HStack(spacing: style == .orb ? 0 : 11) {
            VoiceOrb(mode: mode, level: level)
                .frame(width: style == .orb ? 58 : 40, height: style == .orb ? 58 : 40)
                // The only click target in the smallest style: tapping the orb summons
                // the full window, which is the one thing you always want from here.
                .onTapGesture { Summon.toggle() }

            if style != .orb {
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusLine)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if state.cost.turns > 0 {
                        Text("$" + state.cost.formatted)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textFaint)
                    } else {
                        Text(style == .bar ? "click to connect" : "idle")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if style == .bar {
                HStack(spacing: 6) {
                    Button { state.toggleConnection() } label: {
                        Image(systemName: state.connection == .live ? "stop.fill" : "waveform")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help(state.connection == .live ? "Disconnect" : "Connect")

                    Button { Task { await state.captureAndSend(auto: false) } } label: {
                        Image(systemName: "rectangle.dashed.badge.record")
                    }
                    .buttonStyle(IconButtonStyle())
                    .disabled(state.connection != .live)
                    .help("Show it my screen")
                }
            }
        }
        .padding(.horizontal, style == .orb ? 8 : 13)
        .padding(.vertical, 9)
        .frame(width: style.size.width, height: style.size.height)
        .background(
            RoundedRectangle(cornerRadius: style == .orb ? 39 : 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: style == .orb ? 39 : 16, style: .continuous)
                .stroke(Color.white.opacity(hovering ? 0.22 : 0.12), lineWidth: 1)
        )
        // The whole widget is the drag handle — AppKit moves the window itself, so this
        // is only about not putting a hole in the draggable area.
        .contentShape(RoundedRectangle(cornerRadius: style == .orb ? 39 : 16, style: .continuous))
        .onHover { hovering = $0 }
        .help("Drag to move · click the orb to open FlowState")
    }

    private var statusLine: String {
        switch state.connection {
        case .idle:       return "FlowState"
        case .connecting: return "Connecting…"
        case .error:      return "Needs attention"
        case .live:
            if state.devTaskRunning { return "Working…" }
            if mode == .speaking { return "Speaking" }
            if state.userSpeaking { return "Listening" }
            return "Live"
        }
    }
}
