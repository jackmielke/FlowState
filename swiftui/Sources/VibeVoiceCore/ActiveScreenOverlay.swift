import Foundation
import CoreGraphics

/// Where an overlay that *follows the active screen* belongs — or nowhere at all.
///
/// Two overlays in this app are drawn over everyone else's windows rather than inside
/// FlowState's own: the caption strip (`CaptionBar`) and the floating widget
/// (`HUDWindow`). Both answer the same question every time the pointer settles on
/// another display — which screen am I supposed to be on now, and where on it — and both
/// used to answer it differently and wrongly.
///
/// The rules live here, in Foundation, because the answer is arithmetic on rectangles and
/// a set of display ids. `NSScreen` is only needed to *supply* those, and an overlay that
/// can only be checked by plugging in a second monitor is an overlay that is never
/// checked.
///
/// The one thing to hold on to: **an unresolved active screen means off, not "guess"**.
/// The obvious fallback — `NSScreen.main` — is the screen holding the key window, i.e.
/// FlowState's own. Falling back to it puts the transcript on the screen the user is
/// demonstrably *not* working on, which is the exact failure the whole feature exists to
/// avoid. See `ActiveDisplayGate` for what makes a display active in the first place.
public enum ActiveScreenOverlay {

    /// The display an overlay should be on right now, or nil for "stay off".
    ///
    /// - Parameters:
    ///   - enabled: the user's setting. Off is off; nothing below can turn it back on.
    ///   - active: the settled active display, from `ActiveDisplayGate`. Nil while the
    ///     watcher has not resolved one yet.
    ///   - attached: every display currently plugged in.
    public static func target(enabled: Bool, active: UInt32?, attached: [UInt32]) -> UInt32? {
        guard enabled else { return nil }
        // Nothing to draw on. Real for a moment while displays are being re-enumerated
        // after a monitor is unplugged.
        guard !attached.isEmpty else { return nil }
        // A display that has gone away is not somewhere to put a caption, even if it is
        // still what the watcher last settled on.
        if let active, attached.contains(active) { return active }
        // One screen: there is no wrong answer, so an unresolved pointer is not a reason
        // to withhold the overlay. This is the single-display Mac, which is most of them.
        if attached.count == 1 { return attached[0] }
        // More than one screen and no idea which. Stay off rather than pick.
        return nil
    }

    /// Keeps an overlay in the same *corner* when it moves to another screen.
    ///
    /// Per axis, the distance to whichever edge it is nearer is preserved. A widget
    /// parked 24 points in from the bottom-right of a laptop display arrives 24 points in
    /// from the bottom-right of a 5K one, which is what "the corner" means to the person
    /// who dragged it there.
    ///
    /// The obvious alternative — preserve the position as a fraction of the screen — is
    /// wrong for exactly this case, and it is the only case these overlays have: on a
    /// screen two and a half times as wide, 99.4% of the way across lands fourteen points
    /// further from the edge than it started. Fractions preserve the middle; nothing here
    /// lives in the middle. The caption strip does not use this at all — it re-centres
    /// itself on whatever screen it is handed.
    ///
    /// - Returns: the new origin, already inside `to`.
    public static func moved(_ frame: CGRect, from: CGRect, to: CGRect) -> CGPoint {
        func anchored(low: CGFloat, high: CGFloat, toLow: CGFloat, toHigh: CGFloat,
                      extent: CGFloat) -> CGFloat {
            // Ties go to the low edge. For an overlay as big as the screen that is the
            // only origin that fits anyway.
            low <= high ? toLow + low : toHigh - high - extent
        }
        let x = anchored(low: frame.minX - from.minX, high: from.maxX - frame.maxX,
                         toLow: to.minX, toHigh: to.maxX, extent: frame.width)
        let y = anchored(low: frame.minY - from.minY, high: from.maxY - frame.maxY,
                         toLow: to.minY, toHigh: to.maxY, extent: frame.height)
        return clamped(CGRect(x: x, y: y, width: frame.width, height: frame.height), in: to)
    }

    /// Breathing room kept between an overlay and the edge of the screen it is on.
    public static let inset: CGFloat = 8

    /// Pulls an overlay back onto a screen it has fallen off — a monitor unplugged, a
    /// resolution changed under it, or a follow that landed a point wide.
    ///
    /// Rounded because these become window origins: a half-point origin costs the panel
    /// its crisp edge for no benefit anybody asked for.
    public static func clamped(_ frame: CGRect, in visible: CGRect) -> CGPoint {
        // An overlay wider than the screen cannot satisfy both insets. Favour the near
        // edge, so the part that is on screen is the part that starts at the corner.
        let maxX = max(visible.minX + inset, visible.maxX - frame.width  - inset)
        let maxY = max(visible.minY + inset, visible.maxY - frame.height - inset)
        return CGPoint(x: min(max(frame.minX, visible.minX + inset), maxX).rounded(),
                       y: min(max(frame.minY, visible.minY + inset), maxY).rounded())
    }
}
