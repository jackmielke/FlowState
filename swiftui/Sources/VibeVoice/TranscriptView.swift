import SwiftUI

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
            HStack(spacing: 7) {
                Circle().fill(Theme.textFaint).frame(width: 3, height: 3)
                Text(item.text)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 1)

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
                    Text(item.text)
                        .font(.system(size: 13))
                        .foregroundStyle(isUser ? Theme.text.opacity(0.88) : Theme.text)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
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
