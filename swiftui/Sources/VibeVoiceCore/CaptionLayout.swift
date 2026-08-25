import Foundation
import CoreGraphics

/// The caption strip's geometry: **one width, always, and a height that comes from the
/// text**.
///
/// The strip used to be sized to its content in both directions, on the theory that a
/// two-word caption should be a small pill rather than a wide empty bar. That reads well
/// in a screenshot and badly in motion. Captions arrive as streaming deltas — the line
/// is re-measured and the window re-centred several times a second while the assistant
/// is still talking — so a width that tracks the text means both edges of the strip walk
/// outwards under the words you are trying to read, and every wrap of the last line
/// snaps them back. The thing you are reading is never in the same place twice.
///
/// So: the width is a constant, chosen once per display and independent of what is being
/// said. Only the height moves, and it moves because the text genuinely needs another
/// line. Since the strip is anchored above the Dock, growing means growing *upwards* —
/// the words already on screen stay exactly where they were and a new line appears above
/// them, which is the one kind of movement a reader can follow.
///
/// It lives in Foundation, next to `ActiveScreenOverlay`, for the same reason: this is
/// arithmetic on rectangles, and layout that can only be checked by talking to the app
/// and watching the screen is layout that is never checked.
public enum CaptionLayout {

    /// The width the strip wants on any display big enough to give it.
    ///
    /// Wide enough for a sentence at 15pt without wrapping every few words, narrow enough
    /// to stay a caption rather than become a banner across the desktop.
    public static let preferredWidth: CGFloat = 520

    /// The floor, for a small or heavily-scaled display. Below this the text wraps so
    /// often that the strip is taller than it is wide.
    public static let minimumWidth: CGFloat = 260

    /// Kept clear at each side of the display, so the strip never touches the edge.
    public static let screenMargin: CGFloat = 40

    /// The transparent border inside the panel that the card's shadow spills into. The
    /// panel is this much wider and taller than the card that is actually drawn; the
    /// difference is not clipped, so the shadow keeps its soft edge instead of ending in
    /// a hard line. Mirrors the `.padding(20)` in `CaptionBarView`.
    public static let shadowMargin: CGFloat = 20

    /// How far above the bottom of the usable screen the strip sits. Clear of the Dock,
    /// and clear of the bottom of a full-screen window's own chrome.
    public static let bottomGap: CGFloat = 64

    /// The panel width on a display whose usable area is `visibleWidth` across.
    ///
    /// A pure function of the *screen*, never of the caption: two different sentences on
    /// the same display get the same answer, which is the whole point.
    public static func width(visibleWidth: CGFloat) -> CGFloat {
        // No usable measurement yet — during a display change, or in a snapshot with no
        // screen at all. The preferred width is a better guess than zero.
        guard visibleWidth.isFinite, visibleWidth > 0 else { return preferredWidth }
        return max(minimumWidth, min(preferredWidth, visibleWidth - screenMargin * 2))
    }

    /// The width of the drawn card inside a panel of `panelWidth` — what the text is
    /// given to wrap in.
    ///
    /// Handed to the view rather than left to SwiftUI to infer, so the text wraps at
    /// exactly the width the window was sized to. Letting the two decide separately is
    /// how a strip ends up either clipping its last word or carrying a stripe of empty
    /// background.
    public static func cardWidth(panelWidth: CGFloat) -> CGFloat {
        max(1, panelWidth - shadowMargin * 2)
    }

    /// The height to start from, before anything has been laid out.
    ///
    /// One line of 15pt rounded text, the card's vertical padding, and the shadow margin
    /// top and bottom — i.e. the smallest the strip is ever going to be. It is a guess,
    /// and it is replaced by a real measurement on the first layout; its only job is to
    /// keep the very first frame from being a window of no height at all.
    public static let singleLineHeight: CGFloat = 18 + 11 * 2 + shadowMargin * 2

    /// The panel height for a measured content height.
    ///
    /// - Parameters:
    ///   - measured: what the laid-out content reported.
    ///   - fallback: the height to keep if it reported nothing usable. A hosting view
    ///     asked for its size before its first layout answers zero, and a strip that
    ///     collapsed to nothing for one frame every time a delta arrived would flicker
    ///     far more visibly than one that is briefly a line out of date.
    ///   - visibleHeight: the usable height of the display, so a long caption grows into
    ///     the screen and stops rather than running off the top of it.
    public static func height(measured: CGFloat, fallback: CGFloat,
                              visibleHeight: CGFloat = .infinity) -> CGFloat {
        guard measured.isFinite, measured > 0 else { return fallback }
        // Rounded up, not to nearest: half a point short of what the text asked for is a
        // clipped descender on the bottom line.
        let wanted = measured.rounded(.up)
        guard visibleHeight.isFinite, visibleHeight > 0 else { return wanted }
        return min(wanted, max(1, visibleHeight - bottomGap - ActiveScreenOverlay.inset))
    }

    /// Where the left edge of the panel goes, to sit centred on the display.
    ///
    /// Rounded because it becomes a window origin, and a half-point origin costs the card
    /// its crisp edge. With the width constant this is constant too — which is the
    /// property that actually keeps the text still, more than the fixed width itself.
    public static func originX(panelWidth: CGFloat, visibleMidX: CGFloat) -> CGFloat {
        (visibleMidX - panelWidth / 2).rounded()
    }
}
