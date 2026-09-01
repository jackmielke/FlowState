import Foundation

/// One structural piece of a markdown document.
///
/// Deliberately a small, closed set: this renders assistant speech, task results and
/// summaries — prose with the occasional list, heading or snippet — not a documentation
/// site. Anything unrecognised falls through to `paragraph`, which is always readable.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `depth` is the nesting level, 0 for a top-level item.
    case bullet(text: String, depth: Int)
    /// `marker` is kept verbatim ("2.", "3)") so a list that starts at 4 still says 4.
    case numbered(marker: String, text: String, depth: Int)
    case code(language: String?, text: String)
    case quote(String)
    case rule
}

/// Markdown, reduced to the part this app actually shows.
///
/// Block structure is parsed here — in Core, with no SwiftUI anywhere near it, so the
/// rules are testable. Inline spans (`**bold**`, `_italic_`, `` `code` ``, links) are
/// handed to Foundation's own markdown parser via `attributed`, because re-implementing
/// emphasis nesting is exactly the kind of thing that is wrong in ways nobody notices.
///
/// Why this exists at all: the realtime model writes markdown whether or not it is asked
/// to, and Claude Code's results are markdown by nature. Rendering `**done**` as three
/// literal asterisks in the middle of a sentence is the single most obvious "this is a
/// prototype" tell in the app.
public enum Markdown {

    // MARK: - Blocks

    public static func blocks(_ source: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        var codeLanguage: String?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            // Soft-wrapped lines are one paragraph, which is what markdown means and
            // what makes a re-flowed sidebar look deliberate.
            out.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        for raw in source.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if let body = code {
                    out.append(.code(language: codeLanguage, text: body.joined(separator: "\n")))
                    code = nil
                    codeLanguage = nil
                } else {
                    flushParagraph()
                    code = []
                    let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = lang.isEmpty ? nil : lang
                }
                continue
            }
            if code != nil { code?.append(line); continue }

            if trimmed.isEmpty { flushParagraph(); continue }

            if isRule(trimmed) {
                flushParagraph()
                out.append(.rule)
                continue
            }
            if let h = heading(trimmed) {
                flushParagraph()
                out.append(h)
                continue
            }
            if let b = bullet(line) {
                flushParagraph()
                out.append(b)
                continue
            }
            if let n = numbered(line) {
                flushParagraph()
                out.append(n)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                out.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }
            // A table is not worth a renderer here, but joining its rows into one
            // paragraph is unreadable. Each row stands on its own; the |---|---| rule
            // under the header carries no information once the pipes are gone.
            if trimmed.hasPrefix("|") {
                flushParagraph()
                if isTableDivider(trimmed) { continue }
                out.append(.paragraph(tableRow(trimmed)))
                continue
            }

            paragraph.append(trimmed)
        }

        // An unterminated fence still had content worth showing — a streaming reply is
        // mid-fence for as long as it takes to write the snippet.
        if let body = code, !body.isEmpty {
            out.append(.code(language: codeLanguage, text: body.joined(separator: "\n")))
        }
        flushParagraph()
        return out
    }

    /// True when the whole string is one paragraph with no markdown in it — the common
    /// case for a spoken line, and worth detecting so the renderer can skip the work.
    public static func isPlain(_ source: String) -> Bool {
        if source.contains("\n") { return false }
        return !source.contains(where: { "*_`#>[".contains($0) })
    }

    // MARK: - Inline

    /// The inline spans of one block, as an `AttributedString` SwiftUI can draw.
    ///
    /// - Parameter streaming: true while the text is still arriving, in which case a
    ///   half-written `**bold` is closed rather than shown as asterisks.
    public static func attributed(_ source: String, streaming: Bool = false) -> AttributedString {
        let text = streaming ? closingDanglingMarkers(source) : source
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        if let parsed = try? AttributedString(markdown: text, options: options) { return parsed }
        return AttributedString(source)
    }

    /// The same text with its markers removed — for anywhere an `AttributedString`
    /// cannot go (a tooltip, an accessibility label, a spoken line).
    public static func plain(_ source: String) -> String {
        String(attributed(source).characters)
    }

    /// Closes an emphasis or code span that the stream has not finished writing yet.
    ///
    /// Appending the missing marker rather than deleting the open one is the calmer of
    /// the two: the word turns bold once and stays bold, instead of un-bolding the
    /// instant its closing asterisks arrive.
    public static func closingDanglingMarkers(_ source: String) -> String {
        var out = source
        if occurrences(of: "**", in: out) % 2 == 1 { out += "**" }
        // Fences are the block parser's business; only inline backticks are counted.
        if !out.contains("```"), out.filter({ $0 == "`" }).count % 2 == 1 { out += "`" }
        return out
    }

    // MARK: - Line shapes

    static func heading(_ trimmed: String) -> MarkdownBlock? {
        var level = 0
        for c in trimmed {
            if c == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        // "#tag" is a word, not a heading. The space is what makes it markdown.
        guard rest.first == " " else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    static func bullet(_ line: String) -> MarkdownBlock? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, "-*+•".contains(first) else { return nil }
        let rest = trimmed.dropFirst()
        // Requiring the space is what keeps `*emphasis*` and `**bold**` out of here.
        guard rest.first == " " else { return nil }
        return .bullet(text: rest.trimmingCharacters(in: .whitespaces), depth: depth(of: line))
    }

    static func numbered(_ line: String) -> MarkdownBlock? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix(while: \.isNumber)
        guard (1...3).contains(digits.count) else { return nil }
        let after = trimmed.dropFirst(digits.count)
        guard let punct = after.first, punct == "." || punct == ")" else { return nil }
        let rest = after.dropFirst()
        guard rest.first == " " else { return nil }
        return .numbered(marker: String(digits) + String(punct),
                         text: rest.trimmingCharacters(in: .whitespaces),
                         depth: depth(of: line))
    }

    static func isRule(_ trimmed: String) -> Bool {
        for marker in ["-", "*", "_"] {
            let stripped = trimmed.replacingOccurrences(of: " ", with: "")
            if stripped.count >= 3, stripped.allSatisfy({ String($0) == marker }) { return true }
        }
        return false
    }

    static func isTableDivider(_ trimmed: String) -> Bool {
        let body = trimmed.filter { !" |".contains($0) }
        return !body.isEmpty && body.allSatisfy { $0 == "-" || $0 == ":" }
    }

    static func tableRow(_ trimmed: String) -> String {
        trimmed.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "  ·  ")
    }

    /// Two spaces per level, which is what every list in the wild uses. Capped so a
    /// deeply indented snippet cannot push text off the side of a 372pt sidebar.
    static func depth(of line: String) -> Int {
        let leading = line.prefix { $0 == " " }.count
        return min(3, leading / 2)
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var index = haystack.startIndex
        while let found = haystack.range(of: needle, range: index..<haystack.endIndex) {
            count += 1
            index = found.upperBound
        }
        return count
    }
}
