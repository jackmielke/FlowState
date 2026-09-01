import Foundation

/// One line that is on screen but has not been filled in yet.
public struct PendingTranscript: Equatable, Identifiable, Sendable {
    public let id: UUID
    /// What the line is waiting for, in words. Goes straight into the log line.
    public let label: String
    /// When the thing being transcribed actually happened — not when the placeholder was
    /// made. They are the same today, but the distinction is what makes the timestamp
    /// safe to use for ordering.
    public let at: Date
    /// When the wait started.
    public let openedAt: Date

    public init(id: UUID, label: String, at: Date, openedAt: Date) {
        self.id = id
        self.label = label
        self.at = at
        self.openedAt = openedAt
    }

    public func waited(_ now: Date) -> TimeInterval { now.timeIntervalSince(openedAt) }
}

/// The ledger of transcript updates that have been promised to the screen and not yet
/// delivered.
///
/// The app shows the user's line the moment they stop talking, before the transcription
/// exists — otherwise their own words appear a second or two after the assistant has
/// already answered them, which reads as the app not having heard. The cost of that is a
/// placeholder that something must come back and fill in, and the failure mode is
/// silent: the transcription event never arrives (transcription is off, the socket
/// dropped, the utterance was noise) and a blank line sits in the transcript forever
/// with a blinking dot next to it.
///
/// So every placeholder is opened here and must be closed here. Anything still open past
/// its deadline is reported — to stderr always, and to the user's transcript as a line
/// saying what was not heard, because a line that quietly never resolves is the thing
/// this whole file exists to make impossible.
///
/// Pure bookkeeping on purpose: no clock of its own, no I/O, no view. `now` is always an
/// argument, which is what makes "this waited too long" a testable statement rather than
/// something only reproducible by unplugging the network.
public final class PendingTranscripts {

    private var open: [UUID: PendingTranscript] = [:]

    /// Every placeholder that was abandoned rather than filled in, for the life of the
    /// process. Surfaced in Settings — a number that should be zero is worth showing.
    public private(set) var abandonedCount = 0

    public init() {}

    public var count: Int { open.count }
    public var isEmpty: Bool { open.isEmpty }
    public var all: [PendingTranscript] { open.values.sorted { $0.openedAt < $1.openedAt } }

    public func isPending(_ id: UUID) -> Bool { open[id] != nil }

    /// Notes that `id` is waiting to be filled in.
    public func open(id: UUID, label: String, at: Date, now: Date = Date()) {
        open[id] = PendingTranscript(id: id, label: label, at: at, openedAt: now)
    }

    /// Closes a placeholder because its content arrived.
    ///
    /// - Returns: true if it was actually open. False means the update was committed
    ///   twice, or committed after being swept — both of which the caller needs to know
    ///   about, because it is about to write into a row that may no longer be there.
    @discardableResult
    public func commit(id: UUID) -> Bool {
        open.removeValue(forKey: id) != nil
    }

    /// Closes a placeholder because it is never going to be filled in — a disconnect, a
    /// new conversation, a failed transcription. Counts as abandoned.
    @discardableResult
    public func abandon(id: UUID) -> PendingTranscript? {
        guard let p = open.removeValue(forKey: id) else { return nil }
        abandonedCount += 1
        return p
    }

    /// Everything that has waited longer than `timeout`, removed from the ledger.
    ///
    /// Destructive so a stuck line is reported once rather than every second the
    /// watchdog ticks.
    public func takeOverdue(now: Date, timeout: TimeInterval) -> [PendingTranscript] {
        let stale = open.values.filter { $0.waited(now) >= timeout }.sorted { $0.openedAt < $1.openedAt }
        for p in stale {
            open.removeValue(forKey: p.id)
            abandonedCount += 1
        }
        return stale
    }

    /// Everything still open, removed from the ledger. Used when the ground moves under
    /// the whole transcript: a disconnect, a session switch, a conversation deleted.
    public func takeAll() -> [PendingTranscript] {
        let all = self.all
        open.removeAll()
        abandonedCount += all.count
        return all
    }

    /// How long the oldest outstanding update has been waiting, or nil if none is.
    public func longestWait(now: Date) -> TimeInterval? {
        open.values.map { $0.waited(now) }.max()
    }
}
