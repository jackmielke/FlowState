import Foundation

/// Where the model's voice goes on the recording's timeline.
///
/// The microphone is the clock: it arrives in real time, one buffer per slice of wall
/// time, so the mic write head *is* the present moment. The model's voice does not
/// behave like that at all — a reply is streamed down the socket far faster than it is
/// spoken, so eight seconds of speech can land in a few hundred milliseconds.
///
/// Writing every one of those chunks at the mic head — which is what the first version
/// did — stacks the whole reply on top of itself inside a fraction of a second. The
/// samples are mixed rather than overwritten, so nothing is lost exactly; it is all
/// there, summed, clipping, in the wrong place. Played back it is a half-second of
/// noise where a sentence should be, which reads as "the assistant is muted".
///
/// So the assistant gets its own write head that advances by what it wrote, laying the
/// reply out end to end the way it is actually spoken. It resyncs to the mic head
/// whenever it has fallen into the past, which is what starts each new turn at the
/// moment that turn began instead of immediately after the previous one.
public struct AssistantTimeline: Equatable, Sendable {

    /// The next sample index the assistant will write to.
    public private(set) var head: Int = 0

    public init(head: Int = 0) { self.head = head }

    /// - Parameters:
    ///   - micHead: the mic write head — the present moment, in samples.
    ///   - count: how many samples this chunk carries.
    /// - Returns: the index to write this chunk at.
    public mutating func reserve(count: Int, micHead: Int) -> Int {
        // Behind the present: this is a new turn, not a continuation of the burst.
        if head < micHead { head = micHead }
        let at = head
        head += count
        return at
    }

    /// Called when a recording starts, so a second take does not inherit the first's head.
    public mutating func reset() { head = 0 }
}
