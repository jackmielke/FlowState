import Foundation

/// Dictation: hold a key, talk, and have the words land wherever the cursor already is.
///
/// This is a different shape from the rest of the app. A realtime conversation is a thing
/// you enter and leave; dictation is a thing you do *inside* something else — a Slack
/// message, a commit body, a text field in someone else's app — and the whole value is
/// that it does not take focus. Nothing here draws, and nothing here touches the
/// pasteboard or the accessibility APIs. This is the part that can be reasoned about and
/// tested without a Mac in the loop; `TextInserter` in the app target does the half that
/// needs one.
public enum Dictation {

    /// How far along one utterance is.
    ///
    /// Deliberately linear and deliberately small. The failure this guards is a second
    /// hotkey press arriving while the first utterance is still being transcribed — that
    /// used to be a race in every dictation tool I have looked at, and it shows up as
    /// two half-sentences interleaved at the cursor.
    public enum Phase: String, Equatable, Sendable, Codable {
        case idle
        case listening
        case transcribing
        case inserting
    }

    /// The state machine for one dictation session.
    ///
    /// A struct rather than a class because the interesting part is the transition table,
    /// and a value type makes the tests read as "from this phase, this event, expect
    /// that" rather than as a sequence of mutations on a shared object.
    public struct Session: Equatable, Sendable {

        public private(set) var phase: Phase = .idle

        /// Set when a transition was refused, so the UI can say why rather than looking
        /// like it dropped the key press.
        public private(set) var lastRefusal: String?

        public init() {}

        /// The hotkey went down.
        ///
        /// Refused unless idle. The alternative — cancelling the in-flight utterance and
        /// starting over — loses words the user already said, which is worse than making
        /// them wait the ~300ms for the previous one to land.
        @discardableResult
        public mutating func beginListening() -> Bool {
            guard phase == .idle else {
                lastRefusal = "Still finishing the last one."
                return false
            }
            phase = .listening
            lastRefusal = nil
            return true
        }

        /// The hotkey came up: stop the mic, start turning samples into words.
        @discardableResult
        public mutating func finishListening() -> Bool {
            guard phase == .listening else {
                lastRefusal = "Not listening."
                return false
            }
            phase = .transcribing
            return true
        }

        /// Transcription came back. Empty text is a valid, common outcome — a key press
        /// with no speech — and must return to idle rather than trying to insert "".
        @discardableResult
        public mutating func transcribed(_ text: String) -> Bool {
            guard phase == .transcribing else {
                lastRefusal = "Nothing was being transcribed."
                return false
            }
            phase = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .idle
                : .inserting
            return true
        }

        /// The text reached the other app — or failed to. Either way we are idle again;
        /// a dictation tool that can get stuck is a dictation tool you stop trusting.
        public mutating func finished() {
            phase = .idle
        }

        /// Abandon whatever is in flight. Used by the escape hatch and on app resign.
        public mutating func cancel() {
            phase = .idle
            lastRefusal = nil
        }
    }

    // MARK: - Spoken text cleanup

    /// Spoken punctuation, in the order they must be matched.
    ///
    /// Longest first: "question mark" has to win before "mark" would, and "new paragraph"
    /// before "new line" would if either were a prefix of the other.
    private static let spokenPunctuation: [(phrase: String, replacement: String)] = [
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
        ("question mark", "?"),
        ("exclamation point", "!"),
        ("exclamation mark", "!"),
        ("open paren", "("),
        ("close paren", ")"),
        ("semicolon", ";"),
        ("colon", ":"),
        ("comma", ","),
        ("period", "."),
        ("dash", " - "),
    ]

    /// Filler that gets dropped when it stands alone at the head of an utterance.
    ///
    /// Only at the head, and only as a whole word. "Um" mid-sentence is often quoted
    /// speech or a real word in another language, and a dictation tool that silently
    /// edits the middle of your sentence is one you have to proofread — which defeats it.
    private static let leadingFiller: Set<String> = ["um", "uh", "erm", "ah"]

    /// Turn raw transcript into what the user meant to type.
    ///
    /// The honest caveat, written down because it will come up: spoken-punctuation
    /// replacement is ambiguous and always will be. "The period of time" contains the
    /// word "period". The guard here is that a phrase is only treated as punctuation when
    /// it is not preceded by an article — which catches the common false positives and
    /// misses the exotic ones. Wispr Flow gets this wrong sometimes too; the difference
    /// is that theirs is a model and this is a table, so this one is at least predictable.
    public static func tidy(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        text = stripLeadingFiller(text)
        text = applySpokenPunctuation(text)
        text = tightenSpacing(text)
        text = capitalizeSentences(text)
        return text
    }

    private static func stripLeadingFiller(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        while let first = words.first,
              leadingFiller.contains(first.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }

    private static func applySpokenPunctuation(_ text: String) -> String {
        var result = text
        for (phrase, replacement) in spokenPunctuation {
            result = replaceStandalone(phrase: phrase, with: replacement, in: result)
        }
        return result
    }

    /// Replace `phrase` only where it is a whole word (or words) and not article-led.
    private static func replaceStandalone(phrase: String, with replacement: String, in text: String) -> String {
        // \b won't do here because the phrase can contain a space, and because we need to
        // look back at the previous word to spot "the period".
        let pattern = "(^|[^\\p{L}])(?<!\\bthe )(?<!\\ba )(?<!\\ban )"
            + NSRegularExpression.escapedPattern(for: phrase)
            + "(?=$|[^\\p{L}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        // "$1" keeps whatever boundary character preceded the phrase.
        let template = "$1" + NSRegularExpression.escapedTemplate(for: replacement)
        return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    /// Punctuation hugs the word before it; one space follows it; newlines keep no spaces.
    private static func tightenSpacing(_ text: String) -> String {
        var out = text
        for pair in [(" ,", ","), (" .", "."), (" ?", "?"), (" !", "!"),
                     (" ;", ";"), (" :", ":"), (" )", ")"), ("( ", "(")] {
            out = out.replacingOccurrences(of: pair.0, with: pair.1)
        }
        out = out.replacingOccurrences(of: " *\n *", with: "\n", options: .regularExpression)
        out = out.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Capitalize the first letter, and the first letter after `.`, `?`, `!` or a newline.
    ///
    /// Left deliberately naive about abbreviations. Getting "e.g. this" right requires a
    /// list, and a wrong list capitalizes mid-sentence, which reads worse than a missed
    /// capital at the start of a clause.
    private static func capitalizeSentences(_ text: String) -> String {
        var out = ""
        var capitalizeNext = true
        for ch in text {
            if capitalizeNext, ch.isLetter {
                out.append(Character(ch.uppercased()))
                capitalizeNext = false
            } else {
                out.append(ch)
                if ch == "." || ch == "?" || ch == "!" || ch == "\n" {
                    capitalizeNext = true
                }
            }
        }
        return out
    }
}
