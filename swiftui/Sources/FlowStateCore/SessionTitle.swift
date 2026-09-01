import Foundation

/// What a saved conversation is called in the list.
///
/// A session id (`chat-20260821-150412-9f3a`) is the right name for a file and a useless
/// name for a human, so every session also carries a title. Titles are generated here,
/// from three sources in descending order of how much they actually say:
///
///  1. **Topic** — the first substantive thing the user asked for, with the throat-clearing
///     taken off the front ("hey FlowState, could you…"). This is what people remember a
///     conversation by, and it is available from the very first turn.
///  2. **Context summary** — the running summary, when the user's own lines were all too
///     short to name anything ("yes", "do it", "no, the other one").
///  3. **Date and time** — "Thursday afternoon". Always available, so a session is never
///     nameless, and honest about saying nothing when there is nothing to say.
///
/// Everything here is decidable from its arguments — no clock, no locale lookup that is
/// not passed in, no disk — because a title that quietly changes with the machine it is
/// generated on is a title that cannot be tested. The side that owns the clock is
/// `ConversationStore`.
public enum SessionTitle {

    /// Ceilings on a generated title. Long enough to be specific, short enough to sit in
    /// a 372pt sidebar without eliding into uselessness.
    public static let maxWords = 7
    public static let maxCharacters = 44

    /// How many conversational lines a session gets before its auto title is frozen.
    ///
    /// A title that keeps rewriting itself is a title nobody can find twice — but the
    /// first line of a conversation is often "hey" and nothing else, so the first few
    /// turns are allowed to improve it. A user-set title is never touched at all.
    public static let settlesAfter = 10

    /// The title for a conversation as it currently stands.
    ///
    /// - Parameters:
    ///   - entries: everything recorded in this session, any order.
    ///   - summaries: what has been summarised of it, if anything.
    ///   - startedAt: when the conversation began — the fallback title's whole content.
    ///   - now: the clock the fallback is phrased relative to ("This afternoon").
    public static func make(entries: [ConversationEntry],
                            summaries: [ConversationSummary] = [],
                            startedAt: Date,
                            now: Date = Date(),
                            calendar: Calendar = .current,
                            locale: Locale = .current) -> String {
        if let topic = topic(fromUserLines: entries) { return topic }
        if let fromSummary = topic(fromSummaries: summaries) { return fromSummary }
        return timeLabel(for: startedAt, now: now, calendar: calendar, locale: locale)
    }

    /// True when a title generated earlier should be replaced by a better one.
    ///
    /// Custom titles are never regenerated: a user who renamed a conversation has said
    /// what it is called, and outvoting them because a summary arrived would be the app
    /// arguing with its owner.
    public static func shouldRegenerate(titleIsCustom: Bool, entryCount: Int) -> Bool {
        !titleIsCustom && entryCount <= settlesAfter
    }

    // MARK: - Topic

    /// The first thing the user said that names anything.
    ///
    /// Not simply the first line: openings are "hey", "hi FlowState", "you there?" far more
    /// often than they are the actual question, and a list full of conversations called
    /// "Hey" is a list nobody reads twice.
    static func topic(fromUserLines entries: [ConversationEntry]) -> String? {
        let said = entries
            .filter { $0.speaker == .user }
            .sorted { $0.at < $1.at }
            .prefix(8)
            .map(\.text)

        var best: String?
        for line in said {
            guard let candidate = condense(stripOpeners(line)) else { continue }
            // Three words is where a line stops being an acknowledgement and starts
            // being a request. The first one that clears it wins, because the thing
            // someone opens with is what they came for.
            if candidate.split(separator: " ").count >= 3 { return candidate }
            // Two words can still be a topic ("the notarisation step") but usually is
            // not ("do it", "that one", "go on"). Length is the cheap tell, and getting
            // it wrong only costs a fall-through to the summary or the clock.
            if best == nil, candidate.count >= 12 { best = candidate }
        }
        return best
    }

    /// A topic pulled out of the running summary, for conversations the user drove
    /// entirely in monosyllables.
    static func topic(fromSummaries summaries: [ConversationSummary]) -> String? {
        guard let text = summaries.sorted(by: { $0.createdAt < $1.createdAt }).first?.text
        else { return nil }
        var t = text
        // `ExtractiveSummarizer` opens with this, and repeating it in every title would
        // make every title start with the same four words.
        for lead in ["you asked about ", "the user asked about ", "you asked ", "the user "] {
            if t.lowercased().hasPrefix(lead) {
                t = String(t.dropFirst(lead.count))
                break
            }
        }
        return condense(t)
    }

    /// Openings that carry no information about what the conversation is about.
    ///
    /// Ordered longest-first so "could you please" is taken off before "could you" gets
    /// the chance to leave "please" behind.
    static let openers: [String] = [
        "i was wondering if you could", "i was wondering whether", "i was wondering if",
        "do you think you could", "i would like you to", "i'd like you to",
        "i want you to", "i need you to", "could you please", "can you please",
        "would you please", "quick question", "i was wondering",
        // The app's own name, and every name it has shipped under. The old ones stay:
        // they are still sitting in transcripts recorded before the rename, and a title
        // reading "Vantage can you check the build" helps nobody.
        "hey flowstate", "hey flow state", "hey vantage", "hey vibe", "hey flow",
        "hey there",
        "could you", "can you", "would you", "will you", "help me",
        "i want to", "i need to", "i wanna", "tell me about", "tell me",
        "let's", "lets", "please", "hello", "hey", "hi", "yo",
        "okay", "ok", "alright", "so", "um", "uh", "erm", "well", "actually", "just",
        // Bare, for lines that open on the name alone. "flow" on its own is deliberately
        // NOT here — it is an ordinary word ("flow charts", "the flow of the request")
        // and stripping it would mangle real topics.
        "flowstate", "flow state", "vantage", "vibe",
    ]

    /// Trailing politeness. Same problem as the openers, at the other end.
    static let closers: [String] = ["please", "thanks", "thank you", "if you can", "if you could"]

    /// Takes the throat-clearing off both ends, but never at the cost of the line.
    ///
    /// If stripping leaves fewer than two words there was nothing else in the sentence,
    /// so the original comes back — "Hey" is a bad title, and "" is a worse one.
    static func stripOpeners(_ raw: String) -> String {
        let original = collapseWhitespace(raw)
        var s = original

        var changed = true
        while changed {
            changed = false
            let lower = s.lowercased()
            for opener in openers where lower.hasPrefix(opener) {
                let rest = String(s.dropFirst(opener.count))
                // Only a real word boundary counts, or "hi" would eat the front of
                // "history" and "so" the front of "something".
                guard rest.isEmpty || rest.first == " " || rest.first == "," else { continue }
                s = trimEdges(rest)
                changed = true
                break
            }
        }

        for closer in closers where s.lowercased().hasSuffix(closer) {
            let cut = String(s.dropLast(closer.count))
            if cut.isEmpty || cut.last == " " || cut.last == "," {
                s = trimEdges(cut)
                break
            }
        }

        return s.split(separator: " ").count >= 2 ? s : original
    }

    /// Words that cannot end a title, because they are pointing at the word that was
    /// cut off after them.
    static let danglers: Set<String> = ["and", "but", "or", "the", "a", "an", "to", "of",
                                        "for", "in", "on", "with", "that", "is", "was",
                                        "it", "my", "your", "at", "from", "as", "by",
                                        "so", "about"]

    /// Reduces a spoken line to something that fits on one row of a list.
    ///
    /// Returns nil when what is left says nothing — an empty line, a single "yes", a
    /// stray "mm". Nil is the signal to try the next source, never an error.
    static func condense(_ raw: String) -> String? {
        var s = trimEdges(collapseWhitespace(raw))
        guard !s.isEmpty else { return nil }

        // One sentence. The rest of the utterance is usually context for it.
        if let end = s.firstIndex(where: { ".!?".contains($0) }) {
            let head = trimEdges(String(s[s.startIndex..<end]))
            if head.split(separator: " ").count >= 2 { s = head }
        }

        var truncated = false

        // A clause boundary is a better cut than a word count, when there is one far
        // enough in to leave something behind.
        if s.split(separator: " ").count > maxWords {
            for separator in [",", " — ", " – ", " - ", ";", " because ", " so that ", " so "] {
                guard let r = s.range(of: separator) else { continue }
                let head = trimEdges(String(s[s.startIndex..<r.lowerBound]))
                if head.split(separator: " ").count >= 3 {
                    s = head
                    break
                }
            }
        }

        var words = s.split(separator: " ").map(String.init)
        if words.count > maxWords {
            words = Array(words.prefix(maxWords))
            truncated = true
        }
        s = words.joined(separator: " ")

        if s.count > maxCharacters {
            var cut = String(s.prefix(maxCharacters))
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 12 {
                cut = String(cut[cut.startIndex..<space])
            }
            s = trimEdges(cut)
            truncated = true
        }

        // Never leave a cut sentence holding the door open for the word that came next.
        // Only ever applied to something that WAS cut: a whole sentence is allowed to
        // end in "at", and trimming it would turn "What am I looking at" into a worse
        // title than the one the user actually said.
        if truncated {
            var kept = s.split(separator: " ").map(String.init)
            while let last = kept.last,
                  kept.count > 2,
                  danglers.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
                kept.removeLast()
            }
            s = kept.joined(separator: " ")
        }

        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—"))
        guard !s.isEmpty else { return nil }

        // Two characters is a noise, not a topic.
        guard s.count >= 3, !s.split(separator: " ").isEmpty else { return nil }
        // A single short word ("yes", "sure", "nope") names nothing.
        if s.split(separator: " ").count == 1 && s.count < 9 { return nil }

        if truncated && !s.hasSuffix("…") { s += "…" }
        return capitalizingFirst(s)
    }

    // MARK: - Time

    /// The fallback title: when a conversation happened, phrased the way somebody would
    /// say it out loud.
    public static func timeLabel(for date: Date,
                                 now: Date = Date(),
                                 calendar: Calendar = .current,
                                 locale: Locale = .current) -> String {
        let part = partOfDay(for: date, calendar: calendar)

        if calendar.isDate(date, inSameDayAs: now) { return capitalizingFirst("this " + part) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return capitalizingFirst("yesterday " + part)
        }

        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = locale
        f.timeZone = calendar.timeZone
        if days > 0 && days < 7 {
            f.setLocalizedDateFormatFromTemplate("EEEE")
        } else {
            f.setLocalizedDateFormatFromTemplate("d MMM")
        }
        let stamp = f.string(from: date)
        return capitalizingFirst(stamp.isEmpty ? part : stamp + " " + part)
    }

    /// Morning / afternoon / evening / night, on the boundaries people actually use
    /// rather than the ones a clock would suggest.
    public static func partOfDay(for date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 0..<5:   return "night"
        case 5..<12:  return "morning"
        case 12..<17: return "afternoon"
        case 17..<22: return "evening"
        default:      return "night"
        }
    }

    // MARK: - Text

    static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    static func trimEdges(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r,;:-–—"))
    }

    /// Sentence case, not title case. "The spacing on that button" reads like a person
    /// wrote it; "The Spacing On That Button" reads like a press release.
    static func capitalizingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }
}
