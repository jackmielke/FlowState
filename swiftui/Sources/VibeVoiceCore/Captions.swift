import Foundation

/// What the floating caption should say right now, and whether it should be on screen.
///
/// Subtitles for a conversation, over whatever you are actually doing. The app's own
/// window is usually not in front — it is a voice assistant — so the transcript scrolling
/// in it is invisible exactly when it is most wanted: when the thing has misheard you and
/// you cannot tell whether it is answering the wrong question.
///
/// The rules are all about *when to disappear*, which is the part that decides whether a
/// permanent strip over someone's screen is a feature or an annoyance.
public struct CaptionState: Equatable, Sendable {

    public enum Speaker: Equatable, Sendable { case user, assistant }

    public struct Line: Equatable, Sendable {
        public let speaker: Speaker
        /// What fits.
        public let text: String
        /// All of it, for the hover.
        public let full: String
        public init(speaker: Speaker, text: String, full: String? = nil) {
            self.speaker = speaker
            self.text = text
            self.full = full ?? text
        }
    }

    /// How long a finished line stays up. Long enough to read a sentence you only
    /// half-heard, short enough that it is gone before you look away and back.
    public var lingers: TimeInterval = 4

    /// Longer than this and it is a paragraph, not a caption. The END is kept, not the
    /// beginning: a caption is read while it is being spoken, so the useful part is
    /// always the most recent words.
    public var maxCharacters = 180

    public private(set) var line: Line?
    /// Whether the last thing said had to be cut down to fit. The panel uses it to decide
    /// whether hovering is worth anything.
    public private(set) var wasTruncated = false
    private var updatedAt: Date?
    private var finished = false

    public init() {}

    /// A partial or complete line. Called on every streaming delta.
    public mutating func say(_ speaker: Speaker, _ text: String, at now: Date, done: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        wasTruncated = trimmed.count > maxCharacters
        line = Line(speaker: speaker, text: Self.tail(trimmed, limit: maxCharacters),
                    full: trimmed)
        updatedAt = now
        finished = done
    }

    /// Clears immediately — for hanging up, or for the user switching it off.
    public mutating func clear() {
        line = nil
        updatedAt = nil
        finished = false
        wasTruncated = false
    }

    /// Whether the panel should be on screen.
    ///
    /// A line that is still being spoken never times out, however long it takes. Only a
    /// finished one starts the clock — otherwise a slow, thoughtful answer vanishes
    /// halfway through, which is the worst possible moment.
    public func visible(at now: Date) -> Bool {
        guard line != nil, let updatedAt else { return false }
        guard finished else { return true }
        return now.timeIntervalSince(updatedAt) < lingers
    }

    /// Keeps the last whole words within the limit.
    ///
    /// Whole words, and an ellipsis, because a caption cut mid-word reads as a bug rather
    /// than as an excerpt.
    static func tail(_ s: String, limit: Int) -> String {
        guard s.count > limit else { return s }
        let cut = String(s.suffix(limit))
        guard let space = cut.firstIndex(of: " ") else { return "…" + cut }
        return "…" + cut[cut.index(after: space)...]
    }
}
