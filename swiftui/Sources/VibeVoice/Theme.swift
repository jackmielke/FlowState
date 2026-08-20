import SwiftUI
import AppKit

private func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// One token, two values, resolved by AppKit at draw time against the *effective*
/// appearance of whatever is drawing it. That is what makes `.system` work: nothing
/// has to be recomputed or re-read when macOS flips the desktop under us.
private func dual(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

enum Theme {
    // MARK: Surfaces
    // Dark: deep near-black with a hint of blue, never pure #000.
    // Light: warm paper white, never pure #fff — same reason.
    static let bg          = dual(srgb(0.961, 0.961, 0.969), srgb(0.043, 0.047, 0.055))
    static let panel       = dual(srgb(0.996, 0.996, 1.000), srgb(0.078, 0.082, 0.094))
    static let panelHi     = dual(srgb(1.000, 1.000, 1.000), srgb(0.106, 0.112, 0.129))
    static let hairline    = dual(srgb(0, 0, 0, 0.10),       srgb(1, 1, 1, 0.07))
    static let hairlineHi  = dual(srgb(0, 0, 0, 0.16),       srgb(1, 1, 1, 0.13))

    /// Untinted wash used for chips, pills and the resting state of controls.
    /// Inverts: white-on-dark becomes black-on-light, otherwise it disappears.
    static let fill        = dual(srgb(0, 0, 0, 0.055),      srgb(1, 1, 1, 0.05))
    static let fillHi      = dual(srgb(0, 0, 0, 0.105),      srgb(1, 1, 1, 0.11))
    static let track       = dual(srgb(0, 0, 0, 0.11),       srgb(1, 1, 1, 0.09))
    /// The transcript column reads as a separate sheet: recessed on dark, raised on light.
    static let sidebar     = dual(srgb(1, 1, 1, 0.55),       srgb(0, 0, 0, 0.22))

    // MARK: Text
    // Light values run darker than a straight inversion would suggest: several call
    // sites dim these further with .opacity(0.7…0.8), and on paper that is exactly
    // where small type stops being readable.
    static let text        = dual(srgb(0.09, 0.10, 0.12), srgb(0.93, 0.94, 0.96))
    static let textDim     = dual(srgb(0.26, 0.28, 0.33), srgb(0.58, 0.60, 0.65))
    static let textFaint   = dual(srgb(0.38, 0.40, 0.45), srgb(0.38, 0.40, 0.45))

    // MARK: Accent
    // Two families per hue: a *fill* (something sits on top of it, so it stays bright
    // in both themes) and an *ink* (it sits on the background, so it has to darken on
    // light or it fails contrast — amber on white is the classic offender).

    /// The one accent — a warm signal amber.
    static let accent      = dual(srgb(0.95, 0.55, 0.13), srgb(1.00, 0.62, 0.24))
    static let accentSoft  = dual(srgb(1.00, 0.72, 0.38), srgb(1.00, 0.78, 0.48))
    static let accentDeep  = dual(srgb(0.88, 0.32, 0.08), srgb(0.95, 0.38, 0.15))
    static let accentInk   = dual(srgb(0.70, 0.32, 0.02), srgb(1.00, 0.62, 0.24))

    /// Assistant voice reads cool against the warm user accent.
    static let voice       = dual(srgb(0.20, 0.56, 0.96), srgb(0.42, 0.71, 1.00))
    static let voiceDeep   = dual(srgb(0.34, 0.32, 0.90), srgb(0.45, 0.42, 0.98))
    static let voiceInk    = dual(srgb(0.08, 0.36, 0.76), srgb(0.42, 0.71, 1.00))

    static let good        = dual(srgb(0.06, 0.60, 0.34), srgb(0.36, 0.86, 0.60))
    static let bad         = dual(srgb(0.95, 0.34, 0.34), srgb(1.00, 0.42, 0.42))
    static let badInk      = dual(srgb(0.76, 0.10, 0.10), srgb(1.00, 0.42, 0.42))
    /// Claude Code badge. Solid in both themes so the white label stays readable.
    static let dev         = dual(srgb(0.44, 0.24, 0.74), srgb(0.55, 0.35, 0.82))

    // MARK: On-color
    /// Label colour for anything sitting on an accent/primary fill.
    static let onAccent    = dual(srgb(0.08, 0.06, 0.03, 0.90), srgb(0.06, 0.06, 0.07))
    static let onDev       = dual(srgb(1, 1, 1, 0.95), srgb(1, 1, 1, 0.92))
    /// Top-edge highlight on filled capsules.
    static let gloss       = dual(srgb(1, 1, 1, 0.34), srgb(1, 1, 1, 0.22))

    // MARK: Chrome
    static let knob        = dual(srgb(1, 1, 1), srgb(1, 1, 1))
    static let shadow      = dual(srgb(0, 0, 0, 0.22), srgb(0, 0, 0, 0.50))

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
