import CoreGraphics

/// Telling a click apart from a drag, on a widget where they share every pixel.
///
/// The orb style is 66 points square and the orb is drawn across all of it, so the tap
/// gesture that starts a session covered the entire window and AppKit's
/// `isMovableByWindowBackground` never saw a single event. The widget could be dragged in
/// every style except the small one — which is the style you would most want to move,
/// being the one you leave up all day.
///
/// Giving the orb a margin to grab would work and would look like a mistake: a ring of
/// dead space around a circle. So one gesture does both jobs and this decides which it
/// was, from how far the pointer travelled.
public enum HUDDrag {
    /// How far the pointer may wander and still have meant a click.
    ///
    /// Three points, not one. A click delivered by a hand rather than a test rig moves a
    /// little — more on a trackpad than a mouse, and more from someone talking while they
    /// point at it — and a widget that starts a call when you meant to move it, or slides
    /// away when you meant to click, is worse than either alone.
    public static let slop: CGFloat = 3

    /// Whether a finished gesture should be treated as a click.
    public static func isClick(translation: CGSize) -> Bool {
        magnitude(translation) <= slop
    }

    public static func magnitude(_ t: CGSize) -> CGFloat {
        (t.width * t.width + t.height * t.height).squareRoot()
    }

    /// Where the window goes for a drag that has moved by `translation` from `origin`.
    ///
    /// SwiftUI's y grows downward and AppKit's grows upward, so the vertical component is
    /// subtracted. Getting this backwards produces a widget that runs away from the
    /// pointer, which reads as the drag being broken rather than inverted.
    public static func origin(from origin: CGPoint, translation: CGSize) -> CGPoint {
        CGPoint(x: origin.x + translation.width, y: origin.y - translation.height)
    }

    /// Keeps a dragged window's origin within `bounds`, allowing `bleed` points of it to
    /// hang off the edge.
    ///
    /// Not clamped flush: a widget parked hard against the edge looks stuck rather than
    /// placed, and people do deliberately tuck it half-off to get it out of the way.
    /// What this prevents is losing it entirely — dragged past the edge with no way back
    /// short of resetting the position.
    public static func clamped(_ origin: CGPoint, size: CGSize,
                               in bounds: CGRect, bleed: CGFloat = 0) -> CGPoint {
        let minX = bounds.minX - bleed
        let maxX = bounds.maxX - size.width + bleed
        let minY = bounds.minY - bleed
        let maxY = bounds.maxY - size.height + bleed
        return CGPoint(x: min(max(origin.x, minX), max(minX, maxX)),
                       y: min(max(origin.y, minY), max(minY, maxY)))
    }

    /// The nearest edge to snap to, or nil when the widget is not close enough to any.
    ///
    /// Only horizontal edges. A widget nudged towards the side of the screen is being put
    /// away; one nudged towards the top or bottom is usually just being moved past the
    /// menu bar or the dock, and snapping it there fights the person doing it.
    public enum Edge { case left, right }

    public static func snapEdge(for frame: CGRect, in bounds: CGRect,
                                within: CGFloat = 18) -> Edge? {
        let toLeft = frame.minX - bounds.minX
        let toRight = bounds.maxX - frame.maxX
        guard min(toLeft, toRight) <= within else { return nil }
        return toLeft <= toRight ? .left : .right
    }
}
