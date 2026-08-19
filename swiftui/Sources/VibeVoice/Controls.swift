import SwiftUI

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
                    .fill(Color.white.opacity(configuration.isPressed ? 0.11 : 0.055))
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
            .foregroundStyle(Color(red: 0.06, green: 0.06, blue: 0.07))
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(
                Capsule().fill(
                    LinearGradient(colors: [tint.opacity(0.98), tint.opacity(0.78)],
                                   startPoint: .top, endPoint: .bottom))
                .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1))
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
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.05))
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
                Capsule().fill(Color.white.opacity(0.09)).frame(height: 4)
                Capsule().fill(tint.opacity(0.85)).frame(width: max(4, w * f), height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
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
                            .foregroundStyle(on ? Color.black.opacity(0.85) : Theme.textDim)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(
                                Capsule().fill(on ? tint.opacity(0.92) : Color.white.opacity(0.055))
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
            .fill(isOn ? tint.opacity(0.9) : Color.white.opacity(0.10))
            .frame(width: 38, height: 22)
            .overlay(
                Circle().fill(.white)
                    .frame(width: 17, height: 17)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: isOn ? 8 : -8)
            )
            .contentShape(Capsule())
            .onTapGesture { withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { isOn.toggle() } }
    }
}
