import SwiftUI
import FlowStateCore

/// Markdown, drawn the way the rest of this app is drawn.
///
/// One renderer for every piece of model- or tool-written text in the window — the
/// transcript, task results, summaries — because the alternative is what was here
/// before: `**done**` rendered as three literal asterisks in one view and correctly in
/// none. Block structure comes from `Markdown` in Core (tested); inline spans come from
/// Foundation's own parser.
///
/// It degrades to a plain `Text` when there is no markdown in the string, which is most
/// spoken lines, so the common case costs one substring scan.
struct MarkdownText: View {
    let text: String
    /// Base point size. Headings and code derive from it rather than being fixed, so one
    /// call site can be 10.5pt and another 13pt and both stay in proportion.
    var size: CGFloat = 13
    var color: Color = Theme.text
    var design: Font.Design = .default
    /// True while the text is still arriving, so a half-written `**bold` renders as bold
    /// rather than as asterisks.
    var streaming: Bool = false
    var lineSpacing: CGFloat = 3
    var blockSpacing: CGFloat = 7
    /// Applied per block, matching what `.lineLimit` on a plain `Text` used to do.
    var lineLimit: Int? = nil
    /// Caps how much of a long result is drawn in a small card.
    var maxBlocks: Int? = nil

    private var blocks: [MarkdownBlock] {
        let all = Markdown.blocks(text)
        guard let maxBlocks, all.count > maxBlocks else { return all }
        return Array(all.prefix(maxBlocks))
    }

    var body: some View {
        if Markdown.isPlain(text) {
            plain(text)
        } else {
            VStack(alignment: .leading, spacing: blockSpacing) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            inline(s)

        case .heading(let level, let s):
            Text(Markdown.attributed(s, streaming: streaming))
                .font(.system(size: size + (level <= 2 ? 2 : 1), weight: .semibold, design: design))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .bullet(let s, let depth):
            marker("•", width: 9, depth: depth) { inline(s) }

        case .numbered(let m, let s, let depth):
            marker(m, width: 17, depth: depth) { inline(s) }

        case .quote(let s):
            HStack(alignment: .top, spacing: 8) {
                Capsule().fill(Theme.hairlineHi).frame(width: 2)
                inline(s).foregroundStyle(color.opacity(0.75))
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(_, let body):
            Text(body)
                .font(.system(size: max(9.5, size - 1.5), design: .monospaced))
                .foregroundStyle(color.opacity(0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)))

        case .rule:
            Divider().overlay(Theme.hairline)
        }
    }

    private func marker<C: View>(_ glyph: String, width: CGFloat, depth: Int,
                                 @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(glyph)
                .font(.system(size: size * 0.92, design: design))
                .foregroundStyle(color.opacity(0.55))
                .frame(width: width, alignment: .leading)
            content()
        }
        .padding(.leading, CGFloat(depth) * 12)
    }

    private func inline(_ s: String) -> some View {
        plain(s)
    }

    private func plain(_ s: String) -> some View {
        Text(Markdown.attributed(s, streaming: streaming))
            .font(.system(size: size, design: design))
            .foregroundStyle(color)
            .lineSpacing(lineSpacing)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}
