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

    /// The two thresholds the dial moves, as `a - b * sensitivity`.
    ///
    /// Named constants rather than numbers written into the expressions, because
    /// `ClapCalibration` has to solve these backwards — "what sensitivity would admit a
    /// clap this loud" — and a calibration working from a stale copy of the coefficients
    /// recommends a setting that does not do what it says.
    public static let floorAt: (Float, Float) = (0.34, 0.28)
    /// Bottoms out at 4x rather than 6x for the same reason the floor was lowered: a
    /// clap only six times the room is a real clap in a room with a fan in it, and the
    /// top of the dial has to be able to admit one. The other four rules — length,
    /// quiet-before, decay, matched pair — are what keep that honest.
    public static let ratioAt: (Float, Float) = (22, 18)

    /// How much louder than the room a frame must be. Speech peaks at roughly 4-6× and
    /// this has to sit clear of that even in a quiet room.
    public var attackRatio: Float { Self.ratioAt.0 - Self.ratioAt.1 * sensitivity }

    /// And loud in absolute terms. A silent room makes every ratio enormous, so without
    /// this two keyboard taps are a wake word.
    ///
    /// Reaches 0.06 at the top of the dial rather than 0.12: a quiet clapper at arm's
    /// length from a laptop microphone lands around there, and a floor that cannot go
    /// below their claps is a dial that cannot be turned up enough to hear them. Found by
    /// a calibration test asking for a setting that would admit a 0.12 clap, and getting
    /// one that would not.
    public var floor: Float { Self.floorAt.0 - Self.floorAt.1 * sensitivity }

    /// A clap is over almost immediately.
    public var maxLength: TimeInterval { 0.06 + 0.04 * TimeInterval(sensitivity) }

    /// How quiet it must have been just before. See rule 2 — this is the one that stops
    /// speech.
    public var quietBefore: TimeInterval { 0.34 - 0.14 * TimeInterval(sensitivity) }

    /// How far the clap must have fallen shortly after its peak.
    ///
    /// Measured over the next FEW frames rather than the very next one, and at a
    /// looser fraction. A clap in a real room does not fall to a fifth of its
    /// peak within ten milliseconds — the room rings. Judging on the single next
    /// frame rejected the second clap of a genuine pair with "did not fall away
    /// fast enough", which is the detector refusing a clap for sounding like it
    /// was made indoors.
    ///
    /// The work of telling a clap from a voice is done by the RISE, not by this.
    /// This only has to exclude things that stay loud — a note, a drone, a hum.
    public var decayTo: Float { 0.45 + 0.2 * sensitivity }

    /// How long after the peak the decay is measured over.
    public var decayWindow: TimeInterval { 0.05 }

    /// The gap between the two claps.
    public var minGap: TimeInterval { 0.1 }
    public var maxGap: TimeInterval { 0.55 + 0.25 * TimeInterval(sensitivity) }

    /// How different the two claps may be, as a ratio of the louder to the quieter.
    public var pairTolerance: Float { 2.2 + 1.8 * sensitivity }

    /// How much louder the first loud frame must be than the one immediately before it.
    ///
    /// The sharpest discriminator there is, and the one that survives a processed
    /// microphone. Voice processing — which this app must run, or the assistant hears
    /// itself — applies gain control and suppresses impulsive noise, so a clap arrives
    /// quieter than it was and speech arrives louder. Absolute level then separates the
    /// two badly: measured on this Mac, ordinary speech peaks around 0.11 while a clap
    /// lands near 0.12.
    ///
    /// What processing cannot disguise is the RISE. A clap goes from nothing to its peak
    /// inside one 10 ms frame. A spoken syllable takes three to five frames to get there,
    /// however loud it ends up.
    public var riseRatio: Float { 5 - 2 * sensitivity }

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
    /// The previous frame's peak, for the attack test.
    private var previousPeak: Float = 0
    /// How abrupt this transient's onset was.
    private var transientRise: Float = 0
    private var lastClapAt: TimeInterval?
    private var lastClapPeak: Float = 0
    /// Whether the last loud run was itself accepted as a clap.
    ///
    /// The rule below wants the moment before a clap to be quiet, so that a clap inside a
    /// sentence is read as a syllable. Applied without this, it also rejects the SECOND
    /// CLAP OF EVERY PAIR — the gap people leave is 0.15 to 0.5 seconds and the
    /// quiet-before window is 0.3, so the first clap counts as "other sound" and the pair
    /// can never complete. That is why clapping did not work at all.
    private var previousRunWasClap = false
    private var lastWakeAt: TimeInterval?

    /// The running estimate of the room, for a tuning display.
    public var roomLevel: Float { background }

    /// What a transient has to beat right now. Shown in the tuning panel so "it did not
    /// hear me" becomes "you were 6 dB under".
    public var threshold: Float { Swift.max(background * attackRatio, floor) }

    /// Feeds one frame.
    ///
    /// - Parameters:
    ///   - peak: highest absolute sample in the frame, 0...1.
    ///   - at: the frame's time in seconds, from any fixed origin.
    public mutating func feed(peak: Float, at now: TimeInterval) -> ClapEvent {
        let loud = peak > threshold

        defer {
            previousPeak = peak
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
                transientRise = peak / Swift.max(previousPeak, 0.0005)
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

        // Rule 0, and the strongest: it has to have arrived, not arisen.
        if transientRise < riseRatio {
            lastClapAt = nil
            previousRunWasClap = false
            return .rejected("came up too gradually — that is a voice, not a clap", peak: top)
        }

        if length > maxLength {
            lastClapAt = nil
            previousRunWasClap = false
            return .rejected("too long to be a clap", peak: top)
        }

        // Rule 3: it has to be falling. Judged on this frame, but leniently — see
        // `decayTo`. A room's reverb is not a reason to refuse a clap.
        if peak > top * decayTo {
            lastClapAt = nil
            previousRunWasClap = false
            return .rejected("did not fall away fast enough", peak: top)
        }

        // Rule 2: and it has to have come out of quiet — unless the only thing before it
        // was the other half of this pair. Two claps are not "continuous sound".
        if transientQuietRun < quietBefore && !previousRunWasClap {
            lastClapAt = nil
            previousRunWasClap = false
            return .rejected("came in the middle of other sound", peak: top)
        }

        guard let previous = lastClapAt else {
            lastClapAt = start
            lastClapPeak = top
            previousRunWasClap = true
            return .armed(peak: top)
        }

        let gap = start - previous
        guard gap >= minGap, gap <= maxGap else {
            lastClapAt = start
            lastClapPeak = top
            previousRunWasClap = true
            return .rejected(gap < minGap ? "the two were too close together"
                                          : "too long since the first one", peak: top)
        }

        // Rule 4: a matched pair.
        let ratio = max(top, lastClapPeak) / max(0.0001, min(top, lastClapPeak))
        guard ratio <= pairTolerance else {
            lastClapAt = start
            lastClapPeak = top
            previousRunWasClap = true
            return .rejected("the two did not sound alike", peak: top)
        }

        lastClapAt = nil
        previousRunWasClap = false
        lastWakeAt = now
        return .wake(peak: top)
    }

    /// Forgets what it heard, without forgetting the room.
    public mutating func reset() {
        transientStart = nil
        transientPeak = 0
        transientRise = 0
        previousPeak = 0
        lastClapAt = nil
        previousRunWasClap = false
    }
}
