import Foundation

/// Decides when the pointer has actually moved to another screen, as opposed to passing
/// over one.
///
/// Following the pointer directly would be unusable. Dragging a window from the laptop
/// to the monitor crosses the shared edge, and on the way the cursor sits on the far
/// screen for a few frames — long enough to move a recording onto it and back. The same
/// thing happens reaching for something and returning, and every time the cursor
/// overshoots an edge.
///
/// So a candidate has to hold still. It becomes the active display only once it has been
/// under the pointer continuously for `settle`; anything shorter is a crossing, not a
/// move. That is one number, and it is the whole rule, which is why it lives here where
/// it can be tested rather than inside a timer callback.
public struct ActiveDisplayGate: Equatable, Sendable {

    /// How long a display must hold the pointer before it counts. Half a second is long
    /// enough that no ordinary drag across an edge trips it, and short enough that
    /// deliberately moving to the other screen and starting to work feels immediate.
    public static let defaultSettle: TimeInterval = 0.5

    public private(set) var active: UInt32?

    private var candidate: UInt32?
    private var candidateSince: Date?
    private let settle: TimeInterval

    public init(active: UInt32? = nil, settle: TimeInterval = ActiveDisplayGate.defaultSettle) {
        self.active = active
        self.settle = settle
    }

    /// Feeds one observation.
    ///
    /// - Returns: the new active display, or nil when nothing changed. Returning the
    ///   change rather than the state is what lets callers do work only on a transition —
    ///   moving a window or re-pointing a live capture are both too expensive to redo
    ///   every time the pointer is sampled.
    @discardableResult
    public mutating func observe(_ seen: UInt32?, at now: Date) -> UInt32? {
        // The pointer is between screens, or off all of them. Not a reason to move
        // anything: hold whatever was active and wait for it to land somewhere.
        guard let seen else { candidate = nil; candidateSince = nil; return nil }

        if seen == active {
            candidate = nil
            candidateSince = nil
            return nil
        }

        if seen != candidate {
            candidate = seen
            candidateSince = now
            return nil
        }

        guard let since = candidateSince, now.timeIntervalSince(since) >= settle else { return nil }
        active = seen
        candidate = nil
        candidateSince = nil
        return seen
    }

    /// Adopts a display without waiting — for the moment something starts and has to
    /// pick one, where there is nothing to debounce against yet.
    public mutating func adopt(_ id: UInt32?) {
        active = id
        candidate = nil
        candidateSince = nil
    }
}
