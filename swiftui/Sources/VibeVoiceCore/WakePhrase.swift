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
        score(text) >= WakePhrase.threshold
    }

    /// How close a stretch of the transcript is to the phrase, 0...1.
    ///
    /// A list of spellings is not enough, and the proof came from the robot: its
    /// recogniser heard "hey vibey" as "hey, if I be" — which no variant list
    /// would ever contain. Apple's on-device recogniser mangles "hey flow" the
    /// same way. So the SHAPE of the words is compared instead: the text is run
    /// together and a window slid along it.
    ///
    /// Windows may only begin on an "h". That single constraint is what
    /// separates addressing it from mentioning it — "hey flow" scores 1.00 while
    /// "talking about flow" scores nothing, because the name on its own is
    /// somebody discussing the app rather than calling it.
    public func score(_ text: String) -> Double {
        // Squashed, but remembering where each word began.
        //
        // Anchoring on any "h" is not enough: the h in "the" is an h, so "the
        // flow of the conversation" squashes to something starting "heflowof"
        // and scores as high as the real phrase. A window may only begin where a
        // WORD begins, which is the difference between somebody saying "hey
        // flow" and somebody saying "the flow".
        var chars: [Character] = []
        var wordStarts: Set<Int> = []
        for word in WakePhrase.normalise(text).split(separator: " ") {
            wordStarts.insert(chars.count)
            chars.append(contentsOf: word)
        }
        guard !chars.isEmpty else { return 0 }
        let targets = ([phrase] + variants).map { $0.replacingOccurrences(of: " ", with: "") }
        var best = 0.0
        for start in chars.indices where chars[start] == "h" && wordStarts.contains(start) {
            for target in targets where target.count >= 5 {
                for span in (target.count - 2)...(target.count + 2) {
                    let end = min(start + span, chars.count)
                    guard end - start >= 5 else { continue }
                    best = max(best, WakePhrase.similarity(String(chars[start..<end]), target))
                }
            }
        }
        return best
    }

    /// Catches "hey, if I be" for "hey vibey" and leaves ordinary speech well
    /// under. Measured against real transcripts from both machines.
    public static let threshold = 0.78

    /// Ratio of matching characters, in order, to total length — the same measure
    /// Python's difflib uses, written out because Foundation has no equivalent.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: y.count + 1)
        var longest = 0
        for i in 0..<x.count {
            var current = [Int](repeating: 0, count: y.count + 1)
            for j in 0..<y.count where x[i] == y[j] {
                current[j + 1] = previous[j] + 1
                longest = max(longest, current[j + 1])
            }
            previous = current
        }
        // Longest common run is a poor measure on its own; count all matches in
        // order instead, which is what makes "heyifibe" score against "heyvibey".
        var i = 0, j = 0, matched = 0
        while i < x.count && j < y.count {
            if x[i] == y[j] { matched += 1; i += 1; j += 1 }
            else if x.count - i > y.count - j { i += 1 }
            else { j += 1 }
        }
        return 2.0 * Double(matched) / Double(x.count + y.count)
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
