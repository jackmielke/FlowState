import SwiftUI

enum Theme {
    // Deep near-black with a hint of blue, never pure #000.
    static let bg          = Color(red: 0.043, green: 0.047, blue: 0.055)
    static let panel       = Color(red: 0.078, green: 0.082, blue: 0.094)
    static let panelHi     = Color(red: 0.106, green: 0.112, blue: 0.129)
    static let hairline    = Color.white.opacity(0.07)
    static let hairlineHi  = Color.white.opacity(0.13)

    static let text        = Color(red: 0.93, green: 0.94, blue: 0.96)
    static let textDim     = Color(red: 0.58, green: 0.60, blue: 0.65)
    static let textFaint   = Color(red: 0.38, green: 0.40, blue: 0.45)

    /// The one accent — a warm signal amber.
    static let accent      = Color(red: 1.00, green: 0.62, blue: 0.24)
    static let accentSoft  = Color(red: 1.00, green: 0.78, blue: 0.48)
    static let accentDeep  = Color(red: 0.95, green: 0.38, blue: 0.15)

    /// Assistant voice reads cool against the warm user accent.
    static let voice       = Color(red: 0.42, green: 0.71, blue: 1.00)
    static let voiceDeep   = Color(red: 0.45, green: 0.42, blue: 0.98)

    static let good        = Color(red: 0.36, green: 0.86, blue: 0.60)
    static let bad         = Color(red: 1.00, green: 0.42, blue: 0.42)

    static let ease = Animation.easeOut(duration: 0.22)
}

/// Sheet-of-glass surface used for every raised element.
struct Surface: ViewModifier {
    var radius: CGFloat = 14
    var elevated: Bool = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(elevated ? Theme.panelHi : Theme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(elevated ? Theme.hairlineHi : Theme.hairline, lineWidth: 1)
                    )
            )
    }
}

extension View {
    func surface(_ radius: CGFloat = 14, elevated: Bool = false) -> some View {
        modifier(Surface(radius: radius, elevated: elevated))
    }
}
