import SwiftUI
import AppKit
import VibeVoiceCore

/// What has been said, condensed — and kept somewhere it can be read again.
///
/// Summaries already existed before this panel: they were written on a cadence, spoken
/// into the transcript once, and filed into a markdown note. All three are fine and none
/// of them is "show me the recap of what we just did" — the transcript line scrolls away
/// within a minute, and the note is a file in Application Support. So they land here as
/// well, newest first, for as long as the app is open.
struct SummaryView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    private var summaries: [ConversationSummary] { state.visibleSummaries }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Summary")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
                Button {
                    state.summarizeSessionNow()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: state.isSummarizing ? "ellipsis" : "text.append")
                            .font(.system(size: 11))
                        Text(state.isSummarizing ? "Writing…" : "Summarise now")
                    }
                }
                .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                .disabled(!state.canSummarizeSession)
                .opacity(state.canSummarizeSession ? 1 : 0.5)
                .help(state.summaryButtonHelp)

                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle())
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)

            Divider().overlay(Theme.hairline)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if let problem = state.summaryProblem {
                        Text(problem)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textDim)
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.fill)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Theme.hairline, lineWidth: 1)))
                    }

                    if state.isSummarizing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading the conversation back…")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                        }
                    }

                    if summaries.isEmpty && !state.isSummarizing {
                        empty
                    } else {
                        ForEach(summaries) { card($0) }
                    }

                    Text("Summaries are also appended to a markdown note, one file per day.")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                    HStack(spacing: 10) {
                        Button("Show notes in Finder") {
                            let dir = ConversationStore.notesDirectory
                            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(dir)
                        }
                        .buttonStyle(GhostButtonStyle())
                        if let latest = summaries.first {
                            Button("Copy latest") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(latest.text, forType: .string)
                            }
                            .buttonStyle(GhostButtonStyle())
                        }
                    }
                }
                .padding(22)
            }
        }
        .frame(width: 560, height: 520)
        .background(Theme.bg)
    }

    private var subtitle: String {
        if let id = state.summarySession {
            let turns = state.conversation.conversationalCount(inSession: id)
            let live = state.sessionID == id
            return "\(live ? "This conversation" : "Last conversation") · \(turns) turn\(turns == 1 ? "" : "s") · \(id)"
        }
        return "Nothing recorded yet"
    }

    private var empty: some View {
        VStack(spacing: 7) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(Theme.textFaint.opacity(0.5))
            Text("No summary yet")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textDim)
            Text("Summarise now writes one from what has been said so far.\nOne also gets written on its own every few minutes.")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func card(_ s: ConversationSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(s.createdAt, style: .time)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                if s.id == state.latestSummary?.id {
                    Text("NEWEST")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded)).tracking(0.8)
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accent.opacity(0.9)))
                }
                Spacer()
                Text(range(s))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
            }

            // Rendered as markdown like everything else the model writes: the shipped
            // summariser is plain prose, but a real one is one `init` argument away and
            // will not be.
            MarkdownText(text: s.text, size: 12.5, color: Theme.text, lineSpacing: 3)

            Text("\(s.entryCount) turn\(s.entryCount == 1 ? "" : "s") · written by \(s.generator)")
                .font(.system(size: 10)).foregroundStyle(Theme.textFaint)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(11)
    }

    private func range(_ s: ConversationSummary) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: s.coveringFrom) + "–" + f.string(from: s.coveringTo)
    }
}
