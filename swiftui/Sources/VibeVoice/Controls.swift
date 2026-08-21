import SwiftUI
import VibeVoiceCore
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
        // Same reason as NeatToggle: a drag gesture on a Capsule is invisible to
        // VoiceOver. One adjustable element, stepping a twentieth of the range, with the
        // label and spoken value supplied by whoever placed it.
        .accessibilityElement(children: .ignore)
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
            onCommit()
        }
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
            // Hand-drawn, so nothing here is a control as far as VoiceOver is concerned
            // until we say so. One element, announced as a switch, with the label supplied
            // by whoever placed it.
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAction {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { isOn.toggle() }
            }
    }
}

/// Which screen the assistant is looking at, as a one-click menu.
///
/// Lives under the controls rather than only in Settings, because with two monitors
/// "which screen is it seeing?" is a question you ask mid-conversation, and the answer
/// has to be readable without opening anything. The label is always the display that
/// would be captured right now — never just "Screen".
///
/// Drawn quietly on purpose. It is a statement of what is being shared, and the row
/// above it is where the actions are; giving it the same filled-pill weight as a button
/// made the stage read as four controls when it has three. It gains its outline on
/// hover, so it still tells you it can be clicked at the moment you go to click it.
struct ScreenPicker: View {
    var displays: [DisplayOption]
    /// The display that would be captured right now, whether picked or followed.
    var active: DisplayOption?
    /// True while no explicit pick is set, i.e. the choice tracks the app's own screen.
    var followsActive: Bool
    /// `nil` restores follow-the-active-display.
    var onSelect: (CGDirectDisplayID?) -> Void

    @State private var hovering = false

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
                    .font(.system(size: 9.5))
                // "Showing X" and not just "X": on its own line the name alone would read
                // as a status readout rather than the thing you can change.
                Text("Showing \(label)")
                    .lineLimit(1)
                if displays.count > 1 {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.textFaint.opacity(0.8))
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.textFaint)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Theme.fill : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(hovering ? Theme.hairline : Color.clear, lineWidth: 1)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Theme.ease, value: hovering)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(helpText)
        .accessibilityLabel("Screen shown to FlowState: \(label)")
    }

    private var label: String {
        guard let active else { return "No screen" }
        return followsActive ? "\(active.name) (active)" : active.name
    }

    private var helpText: String {
        guard let active else { return "No display is available to capture." }
        let what = "FlowState sees \(active.name) — \(active.resolution)."
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
                detail: followsActive ? followDetail : "Follow whichever display \(kAssistantDisplayName) is on",
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

/// Header cost control: one click flips Quality ↔ Budget.
///
/// It lives beside the meter because that is where the number it moves is. The mode is
/// the biggest cost dial in the app, and with it reachable only from Settings, noticing
/// the spend and doing something about it were two different places.
struct QualityToggle: View {
    var mode: QualityMode
    var onSelect: (QualityMode) -> Void

    var body: some View {
        Button {
            withAnimation(Theme.ease) { onSelect(mode.next) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 8.5))
                    .contentTransition(.symbolEffect(.replace))
                Text(mode.label.uppercased())
                    .font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(0.8)
            }
            .foregroundStyle(mode == .quality ? Theme.accentInk : Theme.textDim)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Theme.fill)
                .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(mode.label) mode — \(mode.blurb) Click for \(mode.next.label).")
        .accessibilityLabel("Cost mode: \(mode.label)")
    }
}

/// The two switches that decide how FlowState thinks and sounds, one tap from the stage.
///
/// Model and voice were Settings-only, which made the two things most worth swapping
/// mid-conversation the two things that cost a sheet to reach. They sit where the audio
/// format line used to — the same quiet status row, now saying something you can act on.
/// That line is not lost: the negotiated format is this row's tooltip.
struct ModelVoiceBar: View {
    @Binding var model: String
    @Binding var voice: String
    /// What the audio stack actually negotiated, or why it is silent.
    var audioDetail: String
    /// Called after a pick, so a live session hears about it.
    var onChange: () -> Void

    @State private var showModel = false
    @State private var showVoice = false

    var body: some View {
        HStack(spacing: 8) {
            SwitchPill(symbol: "cpu", title: "Model", value: model) { showModel = true }
                .popover(isPresented: $showModel, arrowEdge: .bottom) {
                    popoverBody(title: "Model",
                                note: "Changing the model takes effect on the next connect.") {
                        ChipPicker(options: kModels,
                                   selection: pick($model, close: $showModel),
                                   tint: Theme.voice, columns: 2)
                    }
                }

            SwitchPill(symbol: "waveform", title: "Voice", value: voice) { showVoice = true }
                .popover(isPresented: $showVoice, arrowEdge: .bottom) {
                    popoverBody(title: "Voice",
                                note: "marin and cedar are the newest and best. A live session takes the new voice on its next reply.") {
                        ChipPicker(options: kVoices,
                                   selection: pick($voice, close: $showVoice),
                                   columns: 4)
                    }
                }
        }
        .help(audioDetail)
    }

    /// Writes the pick through, tells the session, and closes the popover — a picker
    /// that stays open after a one-of-many choice reads as if it did not take.
    private func pick(_ value: Binding<String>, close: Binding<Bool>) -> Binding<String> {
        Binding(get: { value.wrappedValue },
                set: { value.wrappedValue = $0; onChange(); close.wrappedValue = false })
    }

    private func popoverBody<C: View>(title: String, note: String,
                                      @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .bold)).tracking(1.0)
                .foregroundStyle(Theme.textFaint)
            content()
            Text(note)
                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// One quiet pill: a label, what it is set to, and a chevron that says it opens.
/// Drawn like `ScreenPicker` — outline on hover only — because it shares that row and
/// should not read as another button competing with the ones above it.
private struct SwitchPill: View {
    let symbol: String
    let title: String
    let value: String
    let tap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 9.5))
                Text(title)
                Text(value)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.textFaint.opacity(0.8))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.textFaint)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Theme.fill : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(hovering ? Theme.hairline : Color.clear, lineWidth: 1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.ease, value: hovering)
        .accessibilityLabel("\(title): \(value)")
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

/// A write-only credential field.
///
/// Never renders the stored secret — once a token is saved there is no reason to display
/// it again, and plenty of reasons not to (screen sharing, screenshots, this very app's
/// screen-capture feature). It shows whether one is set, and lets you replace or clear it.
struct SecureTokenField: View {
    let placeholder: String
    let isSet: Bool
    let onSave: (String) -> Void

    @State private var entry = ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle().fill(isSet || saved ? Theme.good : Theme.textFaint)
                    .frame(width: 6, height: 6)
                Text(isSet || saved ? "Token saved" : "No token yet")
                    .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                Spacer()
                if isSet || saved {
                    Button("Clear") { entry = ""; onSave(""); saved = false }
                        .buttonStyle(GhostButtonStyle(tint: Theme.badInk))
                }
            }
            HStack(spacing: 8) {
                SecureField(placeholder, text: $entry)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .padding(9)
                    .surface(10)
                Button("Save") {
                    onSave(entry)
                    entry = ""
                    saved = true
                }
                .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// The Dev Mode offer, shown inline rather than as a modal.
///
/// A modal would interrupt a voice conversation to advertise a feature, which is exactly
/// the wrong trade. This sits under the orb, waits to be noticed, and takes "Not now" as
/// final.
struct DevOfferCard: View {
    let trigger: DevModeHint.Trigger
    let claudeReady: Bool
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13)).foregroundStyle(Theme.accentInk)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(trigger.headline)
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                Text(trigger.body(claudeReady: claudeReady))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            VStack(spacing: 6) {
                Button(claudeReady ? "Turn it on" : "Show me how", action: onAccept)
                    .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                Button("Not now", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(13)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.fill))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(Theme.accent.opacity(0.35), lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
