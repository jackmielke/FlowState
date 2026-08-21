import SwiftUI
import VibeVoiceCore

/// The top of the sidebar: which conversation you are in, and how to be in another one.
///
/// It sits where the word "TRANSCRIPT" used to, because that label said something the
/// user could already see. What they could not see was that the transcript belongs to a
/// conversation, that there are others, and that this one will still be here tomorrow.
struct SessionBar: View {
    @ObservedObject var state: AppState

    @State private var renaming = false
    @State private var draftTitle = ""
    @State private var confirmingDelete = false

    private var titles: [String: String] { state.sessionTitles }

    private var groups: [(title: String, sessions: [SessionMeta])] {
        SessionCatalog.groupedByAge(state.sessions)
    }

    var body: some View {
        HStack(spacing: 7) {
            Menu {
                menuContents
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 9.5))
                    Text(state.currentSessionTitle)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            // `.button` rather than `.borderlessButton`: the borderless style re-composes
            // the label and drops any background put on it, which left the switcher
            // looking like a plain caption with nothing to say it could be clicked.
            // As a button it honours a ButtonStyle, which is where the capsule lives.
            .menuStyle(.button)
            .buttonStyle(SessionMenuStyle())
            .menuIndicator(.hidden)
            .frame(maxWidth: 250, alignment: .leading)
            .help(switcherHelp)

            Spacer(minLength: 2)

            // The way back to a recap that has already scrolled past. Only appears once
            // there is one, so a plain conversation keeps a plain header.
            if !state.visibleSummaries.isEmpty {
                Button { state.showSummary = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "text.alignleft").font(.system(size: 8.5))
                        Text("\(state.visibleSummaries.count)")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(Theme.accentInk)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.fill))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Summaries of this conversation")
            }

            Text("\(state.transcript.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textFaint.opacity(0.7))
                .help("Lines on screen in this conversation")

            Button { state.newConversation() } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 11))
            }
            .buttonStyle(IconButtonStyle())
            .help("New conversation (⌘N). This one is saved and stays in the list.")
        }
        .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 9)
        .alert("Rename conversation", isPresented: $renaming) {
            TextField("Name", text: $draftTitle)
            Button("Save") { state.renameConversation(state.currentSessionID, to: draftTitle) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to go back to the name Vantage picks from what was said.")
        }
        .alert("Delete this conversation?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                state.deleteConversation(state.currentSessionID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcript and any summaries of it are removed from this Mac. "
                 + "There is no undo.")
        }
    }

    @ViewBuilder
    private var menuContents: some View {
        Button("New conversation") { state.newConversation() }
            .keyboardShortcut("n", modifiers: .command)

        Divider()

        // The way out of a transcript that came back short — a file that was busy when
        // it was read, a conversation written to by something else. It merges rather than
        // replaces, so pressing it when nothing is wrong does nothing at all.
        Button("Reload from disk") { state.refreshTranscript() }
            .keyboardShortcut("r", modifiers: .command)

        Button("Rename…") {
            draftTitle = state.conversation.currentMeta?.titleIsCustom == true
                ? state.currentSessionTitle : ""
            renaming = true
        }
        Button("Delete…") { confirmingDelete = true }

        if !groups.isEmpty {
            Divider()
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.sessions) { meta in
                        Button(label(for: meta)) { state.openConversation(meta.id) }
                    }
                }
            }
        }
    }

    /// The current conversation is marked with a spelled-out checkmark rather than a
    /// system glyph, for the same reason the View menu does it: a menu item's selected
    /// state has to be readable without depending on how the SDK decides to draw it.
    private func label(for meta: SessionMeta) -> String {
        let name = titles[meta.id] ?? meta.title
        let mark = meta.id == state.currentSessionID ? "✓ " : "    "
        return mark + name + (meta.entryCount > 0 ? "  ·  \(meta.entryCount)" : "")
    }

    private var switcherHelp: String {
        let saved = state.sessions.count
        // The title itself, because a long one is truncated in the capsule and hovering
        // is the only way back to the whole of it.
        var help = state.currentSessionTitle + " — everything said in this conversation "
                 + "is saved under this name and comes back after a restart."
        if saved > 1 { help += " \(saved) conversations saved." }
        return help
    }
}


/// The switcher's capsule. Quiet until hovered — it is a label most of the time, and a
/// control only when somebody is looking for one.
private struct SessionMenuStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(configuration.isPressed ? Theme.fillHi : (hovering ? Theme.fill : Color.clear))
                    .overlay(Capsule().stroke(hovering ? Theme.hairlineHi : Theme.hairline,
                                              lineWidth: 1))
            )
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
