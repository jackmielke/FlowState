import Foundation
import CoreGraphics

/// Where a floating pane sits, how big it is, and where a drag leaves it.
///
/// All of it is pure functions of the container size, because the view layer needs the
/// answer on every layout pass and every pointer move — and the moment any of this is
/// computed from mutable state during a view update, or from a coordinate space that is
/// itself moving, the pane starts to shudder. That was the whole of the old glitchiness:
/// a drag measured in the pane's *own* coordinate space, so every point the pane moved
/// subtracted a point from the translation that moved it.
///
/// Kept out of SwiftUI so the rules can be proved rather than eyeballed.
public enum PanelLayout {

    /// Breathing room kept between the pane and the window edge.
    public static let margin: CGFloat = 14

    /// A pane narrower or shorter than this is not a pane, it is a sliver. Applies even
    /// when the window is smaller still — better to overflow a tiny window than to
    /// present something unusable.
    public static let minWidth: CGFloat = 260
    public static let minHeight: CGFloat = 220

    /// The size a pane gets: what it asked for, what its content actually needs, and what
    /// the window can spare — in that order of decreasing authority.
    ///
    /// - Parameter contentHeight: the height the content would take if nothing constrained
    ///   it, or nil before it has been measured. This is what makes the pane contract
    ///   around a short tab and expand for a long one, the way a macOS preferences window
    ///   does, instead of always standing at its maximum with a half-empty scroll view.
    public static func size(ideal: CGSize,
                            contentHeight: CGFloat? = nil,
                            in container: CGSize) -> CGSize {
        let wanted = contentHeight.map { min(ideal.height, max(minHeight, $0)) } ?? ideal.height
        return CGSize(width:  min(ideal.width, max(minWidth,  container.width  - margin * 2)),
                      height: min(wanted,      max(minHeight, container.height - margin * 2)))
    }

    /// The whole "cannot be lost off-screen" guarantee, in one place.
    ///
    /// The `max(margin, …)` on each upper bound matters: in a window too small for the
    /// pane the lower bound would exceed the upper one, and an unordered clamp range is a
    /// crash, not a layout bug.
    public static func clamp(_ p: CGPoint, size s: CGSize, in container: CGSize) -> CGPoint {
        CGPoint(x: min(max(p.x, margin), max(margin, container.width  - s.width  - margin)),
                y: min(max(p.y, margin), max(margin, container.height - s.height - margin)))
    }

    /// Where an unmoved pane sits: centred across, tucked just under the app's own header.
    public static func defaultOrigin(_ s: CGSize, in container: CGSize, top: CGFloat = 64) -> CGPoint {
        clamp(CGPoint(x: (container.width - s.width) / 2, y: top), size: s, in: container)
    }

    /// Where a drag that started with the pane at `anchor` leaves it.
    ///
    /// Absolute from the anchor rather than incremental, so a drag that runs into an edge
    /// and comes back does not leave the pane offset from the pointer by however far it
    /// was clamped.
    public static func dragged(from anchor: CGPoint,
                               by translation: CGSize,
                               size s: CGSize,
                               in container: CGSize) -> CGPoint {
        clamp(CGPoint(x: anchor.x + translation.width, y: anchor.y + translation.height),
              size: s, in: container)
    }

    /// A measured height, rounded and hysteresis-filtered, or nil if it is not worth
    /// reacting to.
    ///
    /// Content measurement arrives as sub-pixel noise — a font metric here, a rounded
    /// scroll inset there — and every accepted value animates the pane. Below the
    /// tolerance the honest answer is "nothing changed".
    public static func settledHeight(_ measured: CGFloat,
                                     current: CGFloat?,
                                     tolerance: CGFloat = 1) -> CGFloat? {
        guard measured.isFinite, measured > 0 else { return nil }
        let rounded = measured.rounded()
        guard let current else { return rounded }
        return abs(rounded - current) >= tolerance ? rounded : nil
    }
}
