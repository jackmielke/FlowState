import SwiftUI
import VibeVoiceCore

struct TranscriptView: View {
    var items: [TranscriptItem]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Color.clear.frame(height: 2)
                    ForEach(items) { item in
                        row(item).id(item.id)
                    }
                    Color.clear.frame(height: 8).id("BOTTOM")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            .onChange(of: items.count) { _, _ in
                withAnimation(.easeOut(duration: 0.28)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
            .onChange(of: items.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: TranscriptItem) -> some View {
        switch item.speaker {
        case .system:
            // Live task steps arrive indented, and the indent is the only thing saying
            // they belong to the line above. Markdown trims leading whitespace, so it is
            // measured before parsing and re-applied as real padding.
            let indent = CGFloat(item.text.prefix { $0 == " " }.count) * 3
            HStack(alignment: .top, spacing: 7) {
                Circle().fill(Theme.textFaint).frame(width: 3, height: 3)
                    .padding(.top, 5)
                // Monospaced, because these lines are ids, paths and tool names — but
                // still markdown, because a Claude Code result lands here verbatim and
                // arrives full of bold and bullets.
                MarkdownText(text: item.text,
                             size: 11,
                             color: Theme.textFaint,
                             design: .monospaced,
                             lineSpacing: 2,
                             blockSpacing: 4)
            }
            .padding(.vertical, 1)
            .padding(.leading, indent)

        default:
            let isUser = item.speaker == .user
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isUser ? Theme.accentInk : Theme.voiceInk)
                        .frame(width: 5, height: 5)
                    Text(isUser ? "YOU" : "VIBE")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(isUser ? Theme.accentInk : Theme.voiceInk)
                    if item.streaming {
                        Circle().fill(Theme.voiceInk)
                            .frame(width: 4, height: 4)
                            .opacity(0.9)
                            .modifier(Blink())
                    }
                    Spacer(minLength: 0)
                    Text(item.at, style: .time)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Theme.textFaint.opacity(0.7))
                }
                if let img = item.image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 92)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Theme.hairlineHi, lineWidth: 1))
                }
                if !item.text.isEmpty {
                    // The model writes markdown whether or not it is asked to, and an
                    // assistant turn arrives a few characters at a time — so a bold span
                    // is half-written for a second or two and must not flash asterisks.
                    MarkdownText(text: item.text,
                                 size: 13,
                                 color: isUser ? Theme.text.opacity(0.88) : Theme.text,
                                 streaming: item.streaming)
                }
            }
            .padding(.leading, 2)
        }
    }
}

private struct Blink: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 0.15 : 1)
            .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}
