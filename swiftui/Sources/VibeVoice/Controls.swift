import SwiftUI
import CoreGraphics

struct GhostButtonStyle: ButtonStyle {
    var tint: Color = Theme.text
    var padH: CGFloat = 14
    var padV: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, padH).padding(.vertical, padV)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(configuration.isPressed ? Theme.fillHi : Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Theme.hairlineHi, lineWidth: 1))
            )
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(
                Capsule().fill(
                    LinearGradient(colors: [tint.opacity(0.98), tint.opacity(0.78)],
                                   startPoint: .top, endPoint: .bottom))
                .overlay(Capsule().stroke(Theme.gloss, lineWidth: 1))
                .shadow(color: tint.opacity(configuration.isPressed ? 0.18 : 0.38), radius: 16, y: 5)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textDim)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Theme.fillHi : Theme.fill)
            )
            .contentShape(Rectangle())
    }
}

/// Slim, hand-rolled slider — no default AppKit chrome anywhere in this app.
struct NeatSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var tint: Color = Theme.accent
    var onCommit: () -> Void = {}

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let f = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track).frame(height: 4)
                Capsule().fill(tint.opacity(0.85)).frame(width: max(4, w * f), height: 4)
                Circle()
                    .fill(Theme.knob)
                    .overlay(Circle().stroke(Theme.hairlineHi, lineWidth: 1))
                    .frame(width: 12, height: 12)
                    .shadow(color: Theme.shadow, radius: 3, y: 1)
                    .offset(x: max(0, w * f - 6))
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let nf = min(1, max(0, g.location.x / max(w, 1)))
                    value = range.lowerBound + Double(nf) * (range.upperBound - range.lowerBound)
                }
                .onEnded { _ in onCommit() })
        }
        .frame(height: 20)
    }
}

/// Segmented chip picker (replaces NSPopUpButton's default look).
struct ChipPicker: View {
    var options: [String]
    @Binding var selection: String
    var tint: Color = Theme.accent
    var columns: Int = 5

    var body: some View {
        let rows = stride(from: 0, to: options.count, by: columns).map {
            Array(options[$0..<min($0 + columns, options.count)])
        }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { opt in
                        let on = opt == selection
                        Text(opt)
                            .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Theme.onAccent : Theme.textDim)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(
                                Capsule().fill(on ? tint.opacity(0.92) : Theme.fill)
                                    .overlay(Capsule().stroke(Theme.hairline, lineWidth: on ? 0 : 1))
                            )
                            .contentShape(Capsule())
                            .onTapGesture { withAnimation(Theme.ease) { selection = opt } }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct NeatToggle: View {
    @Binding var isOn: Bool
    var tint: Color = Theme.accent
    var body: some View {
        Capsule()
            .fill(isOn ? tint.opacity(0.9) : Theme.track)
            .frame(width: 38, height: 22)
            .overlay(
                Circle().fill(Theme.knob)
                    .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                    .frame(width: 17, height: 17)
                    .shadow(color: Theme.shadow, radius: 2, y: 1)
                    .offset(x: isOn ? 8 : -8)
            )
            .contentShape(Capsule())
            .onTapGesture { withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { isOn.toggle() } }
    }
}

/// Which screen the assistant is looking at, as a one-click menu.
///
/// Lives next to Show screen / Watch rather than only in Settings, because with two
/// monitors "which screen is it seeing?" is a question you ask mid-conversation, and the
/// answer has to be readable without opening anything. The label is always the display
/// that would be captured right now — never just "Screen".
struct ScreenPicker: View {
    var displays: [DisplayOption]
    /// The display that would be captured right now, whether picked or followed.
    var active: DisplayOption?
    /// True while no explicit pick is set, i.e. the choice tracks the app's own screen.
    var followsActive: Bool
    /// `nil` restores follow-the-active-display.
    var onSelect: (CGDirectDisplayID?) -> Void

    var body: some View {
        Menu {
            Toggle(isOn: Binding(get: { followsActive },
                                 set: { if $0 { onSelect(nil) } })) {
                Text("Active display — follow me")
            }
            Divider()
            ForEach(displays) { d in
                Toggle(isOn: Binding(get: { !followsActive && d.displayID == active?.displayID },
                                     set: { if $0 { onSelect(d.displayID) } })) {
                    Text("\(d.menuLabel) · \(d.resolution)")
                }
            }
        } label: {
            // The pill is built inside the label, not around the Menu: anything outside
            // the label is drawn but not hit-tested, which would leave most of the
            // control looking clickable and doing nothing.
            HStack(spacing: 6) {
                Image(systemName: followsActive ? "display" : "display.and.arrow.down")
                    .font(.system(size: 10.5))
                // "Showing X" and not just "X": on its own line the name alone would read
                // as a status readout rather than the thing you can change.
                Text("Showing \(label)")
                    .lineLimit(1)
                if displays.count > 1 {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Theme.hairlineHi, lineWidth: 1)))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(helpText)
        .accessibilityLabel("Screen shown to Vibe: \(label)")
    }

    private var label: String {
        guard let active else { return "No screen" }
        return followsActive ? "\(active.name) (active)" : active.name
    }

    private var helpText: String {
        guard let active else { return "No display is available to capture." }
        let what = "Vibe sees \(active.name) — \(active.resolution)."
        return followsActive
            ? what + " Following whichever display this window is on; pick one to pin it."
            : what + " Pinned, so moving this window does not change what it sees."
    }
}

/// The explicit form of the same choice, for Settings — every display listed as a row
/// with its resolution, so a two-identical-monitors setup is still tellable apart.
struct DisplayPicker: View {
    var displays: [DisplayOption]
    var active: DisplayOption?
    var followsActive: Bool
    var onSelect: (CGDirectDisplayID?) -> Void

    var body: some View {
        VStack(spacing: 6) {
            row(title: "Active display",
                detail: followsActive ? followDetail : "Follow whichever display Vibe Voice is on",
                symbol: "display",
                on: followsActive) { onSelect(nil) }

            ForEach(displays) { d in
                row(title: d.menuLabel,
                    detail: d.resolution,
                    symbol: d.isMain ? "menubar.rectangle" : "display.2",
                    on: !followsActive && d.displayID == active?.displayID) { onSelect(d.displayID) }
            }
        }
    }

    private var followDetail: String {
        guard let active else { return "No display available" }
        return "Right now: \(active.name)"
    }

    private func row(title: String, detail: String, symbol: String,
                     on: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(on ? Theme.onAccent : Theme.textDim)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Theme.onAccent : Theme.text)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(on ? Theme.onAccent.opacity(0.75) : Theme.textFaint)
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(on ? Theme.accent.opacity(0.9) : Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: on ? 0 : 1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// Header theme control: one click, one step through System → Light → Dark.
/// The icon is always the mode you are *in*, and the tooltip names the next one,
/// so a three-way choice costs no header width.
struct AppearanceToggle: View {
    @Binding var mode: AppearanceMode

    var body: some View {
        Button {
            withAnimation(Theme.ease) { mode = mode.next }
        } label: {
            Image(systemName: mode.symbol)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(IconButtonStyle())
        .help("Appearance: \(mode.label) — click for \(mode.next.label)")
        .accessibilityLabel("Appearance: \(mode.label)")
    }
}

/// The explicit form of the same choice, for Settings.
struct AppearancePicker: View {
    @Binding var mode: AppearanceMode

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AppearanceMode.allCases, id: \.self) { m in
                let on = m == mode
                Button {
                    withAnimation(Theme.ease) { mode = m }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: m.symbol).font(.system(size: 11))
                        Text(m.label).font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(on ? Theme.accent.opacity(0.9) : Theme.fill)
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Theme.hairline, lineWidth: on ? 0 : 1)))
                    .foregroundStyle(on ? Theme.onAccent : Theme.text)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }
}
