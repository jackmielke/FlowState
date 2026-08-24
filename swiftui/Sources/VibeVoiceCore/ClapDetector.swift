import Foundation

/// Two claps, and it wakes up.
///
/// The wake phrase needs the recogniser to hear words across a room, which is exactly
/// where on-device recognition is weakest. A clap does not need to be understood — it is
/// the loudest, sharpest thing that happens in a quiet room, and that shape is visible in
/// the sample stream without a model, a language, or a network.
///
/// Two, not one. One clap is a door, a mug on a desk, a laptop lid, a cough. The pair —
/// close together but not too close — is what almost nothing else does by accident.
public struct ClapDetector: Equatable, Sendable {

    /// How much louder than the running background a frame must be to count as a
    /// transient. A clap in a normal room is 15-25× the ambient floor; speech peaks are
    /// nearer 4-6×, which is what this has to sit above.
    public var attackRatio: Float = 9

    /// And loud in absolute terms, so that two taps in a silent room — where the floor is
    /// nearly zero and any ratio is enormous — are not claps.
    public var floor: Float = 0.18

    /// A clap is over almost immediately. Anything still loud after this is a voice, a
    /// slammed door, or music.
    public var maxLength: TimeInterval = 0.12

    /// The gap between the two claps. Below the minimum it is one clap echoing, or a
    /// double-strike; above the maximum they are unrelated events.
    public var minGap: TimeInterval = 0.12
    public var maxGap: TimeInterval = 0.7

    /// After waking, ignore everything for this long — including the applause that
    /// follows somebody demonstrating it.
    public var cooldown: TimeInterval = 2.5

    public init() {}

    // MARK: - State

    /// Slow-moving estimate of the room. Rises slowly and falls slowly, so a clap barely
    /// moves it and cannot raise the bar against its own second half.
    private var background: Float = 0.02
    private var transientStart: TimeInterval?
    private var transientPeak: Float = 0
    private var lastClapAt: TimeInterval?
    private var lastWakeAt: TimeInterval?

    /// Feeds one frame of audio.
    ///
    /// - Parameters:
    ///   - peak: highest absolute sample in the frame, 0...1.
    ///   - at: the frame's time, in seconds from any fixed origin.
    /// - Returns: true on the second clap of a pair.
    public mutating func feed(peak: Float, at now: TimeInterval) -> Bool {
        defer {
            // Only the quiet frames teach the background what quiet is.
            if peak < background * attackRatio {
                background += (peak - background) * 0.05
                background = max(background, 0.004)
            }
        }

        if let woke = lastWakeAt, now - woke < cooldown { return false }

        let loud = peak > background * attackRatio && peak > floor

        if loud {
            if transientStart == nil { transientStart = now; transientPeak = peak }
            else { transientPeak = max(transientPeak, peak) }
            return false
        }

        // The frame after a loud run: decide what that run was.
        guard let start = transientStart else { return false }
        let length = now - start
        transientStart = nil
        transientPeak = 0

        // Too long to be a clap — a word, a door, a note.
        guard length <= maxLength else { lastClapAt = nil; return false }

        guard let previous = lastClapAt else { lastClapAt = start; return false }
        let gap = start - previous
        if gap >= minGap && gap <= maxGap {
            lastClapAt = nil
            lastWakeAt = now
            return true
        }
        // Not a pair. This clap becomes the candidate for the next one rather than being
        // thrown away, so three claps still contain a valid pair.
        lastClapAt = start
        return false
    }

    /// Forgets what it heard, without forgetting the room. For when the microphone has
    /// been closed and reopened.
    public mutating func reset() {
        transientStart = nil
        transientPeak = 0
        lastClapAt = nil
    }
}
