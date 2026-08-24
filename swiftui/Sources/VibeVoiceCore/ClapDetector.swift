import Foundation

/// What one frame of audio turned out to be. The rejections carry their reason because
/// tuning a wake trigger is impossible without them: "it did not fire" is not a fact you
/// can act on, and "it was 3 dB under the floor" is.
public enum ClapEvent: Equatable, Sendable {
    case nothing
    /// A sharp transient that could be the first of a pair.
    case armed(peak: Float)
    /// A transient that was rejected, and why.
    case rejected(String, peak: Float)
    /// The second of a pair. Wake up.
    case wake(peak: Float)
}

/// Two claps, and it wakes up.
///
/// The wake phrase needs the recogniser to hear words across a room, which is where
/// on-device recognition is weakest. A clap does not have to be understood, only heard:
/// it is the sharpest, loudest thing that happens in a quiet room, and that shape is in
/// the sample stream already — no model, no language, no network.
///
/// Everything here exists to answer one question: how does a clap differ from every other
/// loud noise a room makes? The answers, in order of how much work they do:
///
///  1. **It is short.** Speech, music and a slammed door all stay loud for longer.
///  2. **It starts from quiet.** A clap inside a sentence is a syllable. Requiring the
///     moment before it to be quiet is what stops speech triggering it, and it is the
///     single most effective rule here.
///  3. **It decays immediately.** The frame after a clap is near the floor. A cough or a
///     thump tails off.
///  4. **It comes in a matched pair.** Two claps from the same hands are within a few dB
///     of each other; a door followed by a cough is not.
public struct ClapDetector: Equatable, Sendable {

    /// 0...1. Everything below scales with it, so there is one dial rather than five.
    /// Higher is easier to trigger.
    public var sensitivity: Float = 0.5

    public init(sensitivity: Float = 0.5) { self.sensitivity = sensitivity }

    /// How much louder than the room a frame must be. 14× at the default, because speech
    /// peaks at roughly 4-6× and this has to sit clear of that even in a quiet room.
    public var attackRatio: Float { 22 - 16 * sensitivity }

    /// And loud in absolute terms. A silent room makes every ratio enormous, so without
    /// this two keyboard taps are a wake word.
    public var floor: Float { 0.34 - 0.22 * sensitivity }

    /// A clap is over almost immediately.
    public var maxLength: TimeInterval { 0.06 + 0.04 * TimeInterval(sensitivity) }

    /// How quiet it must have been just before. See rule 2 — this is the one that stops
    /// speech.
    public var quietBefore: TimeInterval { 0.34 - 0.14 * TimeInterval(sensitivity) }

    /// The frame after the clap must have fallen to this fraction of its peak.
    public var decayTo: Float { 0.22 + 0.18 * sensitivity }

    /// The gap between the two claps.
    public var minGap: TimeInterval { 0.1 }
    public var maxGap: TimeInterval { 0.55 + 0.25 * TimeInterval(sensitivity) }

    /// How different the two claps may be, as a ratio of the louder to the quieter.
    public var pairTolerance: Float { 2.2 + 1.8 * sensitivity }

    /// After waking, ignore everything — including the applause that follows somebody
    /// demonstrating it.
    public var cooldown: TimeInterval { 2.5 }

    // MARK: - State

    private var background: Float = 0.02
    private var lastLoudAt: TimeInterval?
    private var transientStart: TimeInterval?
    private var transientPeak: Float = 0
    /// How long the room had been quiet when this transient began.
    ///
    /// Captured at the start rather than measured at the end, because the transient
    /// itself updates `lastLoudAt` on every one of its own frames — so by the time there
    /// is something to judge, the gap it should be judged against reads as zero and the
    /// rule silently never fires. Which is exactly what it did.
    private var transientQuietRun: TimeInterval = .greatestFiniteMagnitude
    private var lastClapAt: TimeInterval?
    private var lastClapPeak: Float = 0
    private var lastWakeAt: TimeInterval?

    /// The running estimate of the room, for a tuning display.
    public var roomLevel: Float { background }

    /// Feeds one frame.
    ///
    /// - Parameters:
    ///   - peak: highest absolute sample in the frame, 0...1.
    ///   - at: the frame's time in seconds, from any fixed origin.
    public mutating func feed(peak: Float, at now: TimeInterval) -> ClapEvent {
        let threshold = max(background * attackRatio, floor)
        let loud = peak > threshold

        defer {
            if !loud {
                background += (peak - background) * 0.05
                background = max(background, 0.004)
            } else {
                lastLoudAt = now
            }
        }

        if let woke = lastWakeAt, now - woke < cooldown {
            return loud ? .rejected("still settling after the last wake", peak: peak) : .nothing
        }

        if loud {
            if transientStart == nil {
                transientStart = now
                transientPeak = peak
                transientQuietRun = lastLoudAt.map { now - $0 } ?? .greatestFiniteMagnitude
            } else {
                transientPeak = max(transientPeak, peak)
            }
            return .nothing
        }

        // The first quiet frame after a loud run: decide what that run was.
        guard let start = transientStart else { return .nothing }
        let top = transientPeak
        let length = now - start
        transientStart = nil
        transientPeak = 0

        if length > maxLength {
            lastClapAt = nil
            return .rejected("too long to be a clap", peak: top)
        }

        // Rule 3: it has to fall off a cliff.
        if peak > top * decayTo {
            lastClapAt = nil
            return .rejected("did not fall away fast enough", peak: top)
        }

        // Rule 2: and it has to have come out of quiet.
        if transientQuietRun < quietBefore {
            lastClapAt = nil
            return .rejected("came in the middle of other sound", peak: top)
        }

        guard let previous = lastClapAt else {
            lastClapAt = start
            lastClapPeak = top
            return .armed(peak: top)
        }

        let gap = start - previous
        guard gap >= minGap, gap <= maxGap else {
            lastClapAt = start
            lastClapPeak = top
            return .rejected(gap < minGap ? "the two were too close together"
                                          : "too long since the first one", peak: top)
        }

        // Rule 4: a matched pair.
        let ratio = max(top, lastClapPeak) / max(0.0001, min(top, lastClapPeak))
        guard ratio <= pairTolerance else {
            lastClapAt = start
            lastClapPeak = top
            return .rejected("the two did not sound alike", peak: top)
        }

        lastClapAt = nil
        lastWakeAt = now
        return .wake(peak: top)
    }

    /// Forgets what it heard, without forgetting the room.
    public mutating func reset() {
        transientStart = nil
        transientPeak = 0
        lastClapAt = nil
    }
}
