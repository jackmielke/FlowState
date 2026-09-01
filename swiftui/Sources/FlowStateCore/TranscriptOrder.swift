import Foundation

/// Where a line belongs in a transcript.
///
/// A conversation does not arrive in the order it happened. The user's words come off
/// the socket a second or more after they said them — `speech_stopped` and
/// `input_audio_transcription.completed` are different events, and the model has usually
/// started answering in between — so a transcript built by appending in arrival order
/// puts the reply above the question. Worse, it did so only on screen: reading the same
/// conversation back off disk sorts by timestamp, so the history a user saw live and the
/// history they saw after a restart disagreed about who spoke first.
///
/// The fix is to have one rule, here, used by both: a line goes where its timestamp says
/// it goes.
public enum TranscriptOrder {

    /// The index at which a line stamped `at` belongs, in a transcript already ordered by
    /// time.
    ///
    /// Ties go *after* the equal timestamps, so two lines minted in the same millisecond
    /// stay in the order they were produced. That matters more than it sounds: a system
    /// note written immediately after a user line is about that line, and floating above
    /// it would read as being about the one before.
    public static func insertionIndex(for at: Date, in stamps: [Date]) -> Int {
        // The overwhelmingly common case is a line stamped now, arriving last.
        if let last = stamps.last, last <= at { return stamps.count }

        var lo = 0
        var hi = stamps.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if stamps[mid] <= at { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// True when every line is at or after the one before it.
    ///
    /// Used as a cheap invariant after any insertion or re-stamp: a transcript that has
    /// fallen out of order is a bug that is otherwise only visible to somebody reading
    /// the screen carefully.
    public static func isOrdered(_ stamps: [Date]) -> Bool {
        guard stamps.count > 1 else { return true }
        for i in 1..<stamps.count where stamps[i] < stamps[i - 1] { return false }
        return true
    }

    /// Whether a line at `index` is still in the right place after its timestamp changed.
    ///
    /// A placeholder is inserted when the user stops speaking and re-stamped when the
    /// transcription lands, and anything appended in between — a system note, a Claude
    /// Code step — may now belong on the other side of it.
    public static func isSettled(index: Int, in stamps: [Date]) -> Bool {
        guard stamps.indices.contains(index) else { return true }
        let at = stamps[index]
        if index > 0, stamps[index - 1] > at { return false }
        if index + 1 < stamps.count, stamps[index + 1] < at { return false }
        return true
    }
}
