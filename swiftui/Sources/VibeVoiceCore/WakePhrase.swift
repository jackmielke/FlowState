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
    public private(set) var lastFiredAt: Date?

    /// Ignore everything until this moment. For the panic key — see `AppState.hush`.
    public private(set) var snoozedUntil: Date?

    /// The shortest gap between two wakes, so a phrase heard twice as the recogniser
    /// settles cannot open two sessions.
    public var cooldown: TimeInterval = 3

    /// Only the end of the transcript is considered.
    ///
    /// A continuous recognition task reports ONE transcript that grows for as long as the
    /// task lives — up to a minute here. So a phrase said once stays in that string
    /// forever, and a simple "does it contain the phrase" is true from then on. Matching
    /// only the tail means the phrase stops counting as soon as enough has been said
    /// after it, which is what makes "said just now" different from "said at some point".
    public var tailCharacters = 45

    /// Length of the transcript when it last fired, so growth past the match re-arms it
    /// without needing the recogniser to declare the utterance over — which, on device
    /// and mid-flow, it often does not.
    private var firedAtLength: Int?

    public init() {}

    public mutating func snooze(until: Date) { snoozedUntil = until }

    public func isSnoozed(at now: Date) -> Bool {
        guard let snoozedUntil else { return false }
        return now < snoozedUntil
    }

    /// - Parameter transcript: everything heard in the current utterance so far.
    /// - Returns: true exactly once per saying of the phrase.
    public mutating func heard(_ transcript: String,
                               phrase: WakePhrase,
                               now: Date) -> Bool {
        let normalised = WakePhrase.normalise(transcript)
        let tail = String(normalised.suffix(tailCharacters))
        guard phrase.matches(tail) else {
            // The phrase has scrolled out of the tail: whatever was said is over.
            if let fired = firedAtLength, normalised.count > fired { firedAtLength = nil }
            return false
        }
        guard !isSnoozed(at: now) else { return false }
        if let fired = firedAtLength {
            // Same saying of it, reported again as the recogniser refines the line.
            guard normalised.count > fired + tailCharacters else { return false }
        }
        if let last = lastFiredAt, now.timeIntervalSince(last) < cooldown { return false }
        firedAtLength = normalised.count
        lastFiredAt = now
        return true
    }

    /// The recogniser finished an utterance, or was restarted, and the next one starts
    /// from nothing.
    public mutating func utteranceEnded() { firedAtLength = nil }

    /// True when a wake would be allowed right now, ignoring what was said.
    public var armed: Bool { firedAtLength == nil }
}
