import Foundation

/// Decides when to mention Dev Mode, and when to shut up about it.
///
/// The rule this exists to enforce is restraint. An app that nags about an unused feature
/// is worse than one that never mentions it, so this offers at most once, only when there
/// is a reason, and never again once dismissed.
public enum DevModeHint {

    public enum Trigger: Equatable {
        /// They just asked for something Dev Mode would have done.
        case askedForCodeWork(phrase: String)
        /// They have used it a bit and might not know the feature exists.
        case settledIn

        public var headline: String {
            switch self {
            case .askedForCodeWork: return "Want me to actually do that?"
            case .settledIn:        return "I can change code too"
            }
        }

        public func body(claudeReady: Bool) -> String {
            let what: String
            switch self {
            case .askedForCodeWork:
                what = "That sounded like a coding task. With Dev Mode on I can hand it to "
                     + "Claude Code and tell you when it's done."
            case .settledIn:
                what = "Dev Mode lets you say what you want changed in a repo, and I'll make "
                     + "it happen while we keep talking."
            }
            return claudeReady
                ? what + " It runs on your machine, under your own Claude account."
                : what + " It needs Claude Code installed and signed in — one npm install."
        }
    }

    /// Phrases that mean "do something to my code", chosen to be things people actually
    /// say out loud rather than words that merely appear near programming.
    ///
    /// Kept deliberately narrow: a false positive interrupts a conversation, and the
    /// settled-in trigger will get there anyway.
    static let codeIntent: [String] = [
        "can you change", "can you fix", "can you add", "can you update",
        "could you change", "could you fix", "could you add",
        "change the code", "fix the code", "update the code", "edit the code",
        "in my repo", "in the repo", "in my codebase", "in the codebase",
        "add a button", "add a toggle", "add a setting",
        "make it so", "refactor", "commit that", "push that",
    ]

    /// Whether anything in this user turn asks for code work.
    public static func codeIntent(in transcript: String) -> String? {
        let t = transcript.lowercased()
        return codeIntent.first { t.contains($0) }
    }

    /// The offer to make, if any.
    ///
    /// - Parameters:
    ///   - devModeOn: never offer something already on.
    ///   - dismissed: a "not now" is permanent; asking twice is nagging.
    ///   - assistantTurns: how much conversation has happened.
    ///   - lastUserTranscript: the sentence just spoken, if it was transcribed.
    public static func offer(devModeOn: Bool,
                             dismissed: Bool,
                             assistantTurns: Int,
                             lastUserTranscript: String?) -> Trigger? {
        guard !devModeOn, !dismissed else { return nil }

        if let t = lastUserTranscript, let phrase = codeIntent(in: t) {
            return .askedForCodeWork(phrase: phrase)
        }
        // Three replies in means they are actually using it, not poking at it.
        return assistantTurns >= 3 ? .settledIn : nil
    }
}
