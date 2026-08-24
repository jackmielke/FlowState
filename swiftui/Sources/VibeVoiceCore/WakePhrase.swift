import Foundation

/// Deciding whether somebody just said the wake phrase.
///
/// Separate from the recogniser because the recogniser is the easy half. What makes a
/// wake word usable is everything around the match: that "flow" on its own is not it,
/// that a running transcript which keeps growing does not fire again on every update,
/// and that the phrase can be heard as several different things and still count.
public struct WakePhrase: Equatable, Sendable {

    /// What to listen for, already lowercased and stripped.
    public let phrase: String

    /// Alternatives the recogniser produces for the same sound. On-device recognition is
    /// worse than the cloud, and it is confidently worse — "hey flow" comes back as
    /// "hey flo", "hey floe", "a flow". Listing them is cheaper than lowering the bar
    /// for everything.
    public let variants: [String]

    public init(phrase: String, variants: [String] = []) {
        self.phrase = WakePhrase.normalise(phrase)
        self.variants = variants.map(WakePhrase.normalise)
    }

    public static let heyFlow = WakePhrase(
        phrase: "hey flow",
        variants: ["hey flo", "hey floe", "hey flow state", "hey flowstate", "he flow"])

    public static let heyFlowState = WakePhrase(
        phrase: "hey flowstate",
        variants: ["hey flow state", "hey flow stayed", "hey flo state"])

    /// Lowercased, punctuation removed, runs of whitespace collapsed.
    ///
    /// Punctuation matters: the recogniser writes "Hey, Flow." and a naive contains-check
    /// on "hey flow" then never matches the one phrasing it produces most.
    public static func normalise(_ text: String) -> String {
        let stripped = text.lowercased().map { ch -> Character in
            ch.isLetter || ch.isNumber || ch.isWhitespace ? ch : " "
        }
        return String(stripped).split(separator: " ").joined(separator: " ")
    }

    public func matches(_ text: String) -> Bool {
        let hay = WakePhrase.normalise(text)
        return ([phrase] + variants).contains { !$0.isEmpty && hay.contains($0) }
    }
}

/// Watches a growing transcript and fires once per utterance.
///
/// A live recogniser reports the same sentence over and over as it refines it, so a
/// plain match fires on every update for as long as the phrase stays in the text. The
/// rule is: once fired, stay quiet until the transcript has been reset — which is what
/// the end of an utterance looks like from here.
public struct WakeListenerState: Equatable, Sendable {
    public private(set) var armed = true
    public private(set) var lastFiredAt: Date?

    /// Ignore everything until this moment.
    ///
    /// For the panic key. Hanging up on an accidental wake is not enough on its own —
    /// whatever triggered it is still happening, so the clap that opened a session by
    /// mistake opens another one two seconds later and the user is now fighting the app.
    /// Silence has to be something you can ask for, not just something you hope for.
    public private(set) var snoozedUntil: Date?

    public mutating func snooze(until: Date) { snoozedUntil = until }

    public func isSnoozed(at now: Date) -> Bool {
        guard let snoozedUntil else { return false }
        return now < snoozedUntil
    }

    /// The shortest gap between two wakes, so a phrase heard twice as the recogniser
    /// settles cannot open two sessions.
    public var cooldown: TimeInterval = 3

    public init() {}

    /// - Parameter transcript: everything heard in the current utterance so far.
    /// - Returns: true exactly once per utterance containing the phrase.
    public mutating func heard(_ transcript: String,
                               phrase: WakePhrase,
                               now: Date) -> Bool {
        guard phrase.matches(transcript) else { return false }
        guard !isSnoozed(at: now) else { return false }
        guard armed else { return false }
        if let last = lastFiredAt, now.timeIntervalSince(last) < cooldown { return false }
        armed = false
        lastFiredAt = now
        return true
    }

    /// The recogniser finished an utterance and the next one starts from nothing.
    public mutating func utteranceEnded() { armed = true }
}
