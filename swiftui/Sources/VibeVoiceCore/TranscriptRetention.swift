import Foundation

/// How much of the conversation history survives, and which parts of it are exempt.
///
/// `TranscriptPrivacy` already answers "how long may a transcript live" in hours. This
/// answers the other half of the same question — "how MANY may live at all" — and the
/// third thing people actually mean when they ask for control over a record: "write
/// nothing unless I say so".
///
/// The unit here is a conversation, not a line. A transcript is the thing a user names,
/// reopens and deletes, so "keep the last ten" has to mean ten conversations; trimming
/// somebody's current conversation down to its last N lines would silently rewrite the
/// thing they are reading.
///
/// Every rule is decidable from its arguments, which is why it lives in Core and not
/// next to the file handle — see `ConversationStore` for the half that touches disk.
public struct TranscriptRetention: Codable, Equatable, Sendable {

    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Every conversation is written as it happens and kept until the retention
        /// window (or the user) removes it. The default, and the only mode in which
        /// nothing has to be remembered by the person using it.
        case keepEverything
        /// Written as it happens, but only the newest `keepLast` conversations stay on
        /// disk. Pinned ones do not count against the limit and are never trimmed.
        case keepLast
        /// Nothing is written automatically. A conversation reaches disk when the user
        /// saves it or pins it, and not before.
        case manualSave

        public var label: String {
            switch self {
            case .keepEverything: return "Keep everything"
            case .keepLast:       return "Keep last"
            case .manualSave:     return "Only what I save"
            }
        }
    }

    public var mode: Mode
    /// How many conversations survive in `.keepLast`. Clamped on the way in — a limit of
    /// zero would mean "delete the conversation I am having", which is not a retention
    /// policy, it is a bug.
    public var keepLast: Int

    public init(mode: Mode = .keepEverything, keepLast: Int = 20) {
        self.mode = mode
        self.keepLast = Self.clamp(keepLast)
    }

    public static let limits = 1...200

    public static func clamp(_ n: Int) -> Int {
        min(limits.upperBound, max(limits.lowerBound, n))
    }

    /// Whether a line recorded now should be written to disk without being asked.
    ///
    /// Pinned conversations autosave in every mode, including `.manualSave`: a lock that
    /// did not survive quitting would be a promise the app cannot keep.
    public func autosaves(pinned: Bool) -> Bool {
        mode != .manualSave || pinned
    }

    /// The conversations to delete to bring the collection back inside the policy,
    /// newest kept first.
    ///
    /// Three things are never in the returned list, and each for its own reason:
    /// pinned conversations (the user said keep this), the one currently open (deleting
    /// what somebody is looking at is not retention), and — in any mode but `.keepLast` —
    /// everything, because no other mode counts.
    public func sessionsToTrim(_ sessions: [SessionMeta],
                               current: String? = nil) -> [String] {
        guard mode == .keepLast else { return [] }
        let ordered = sessions.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id > $1.id : $0.updatedAt > $1.updatedAt
        }
        var kept = 0
        var doomed: [String] = []
        for meta in ordered {
            if meta.pinned || meta.id == current { continue }
            kept += 1
            if kept > keepLast { doomed.append(meta.id) }
        }
        return doomed
    }

    /// A line for the UI and for the assistant to say out loud.
    public var summaryLine: String {
        switch mode {
        case .keepEverything:
            return "Every conversation is saved and stays until you delete it."
        case .keepLast:
            return "The last \(keepLast) conversation\(keepLast == 1 ? "" : "s") stay saved; pinned ones always do."
        case .manualSave:
            return "Nothing is saved unless you save or pin it."
        }
    }
}
