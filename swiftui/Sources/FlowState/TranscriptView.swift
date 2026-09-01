import SwiftUI
import FlowStateCore

/// The conversation, as a column you can read, correct and delete from.
///
/// Two things it deliberately is not: ephemeral, and read-only. Every line stays here
/// for the whole conversation and comes back after a relaunch — nothing in this view
/// removes anything, and the only paths that do are the ones the user pressed. And a
/// line that was misheard can be rewritten in place rather than argued with: voice
/// transcription gets names, jargon and accents wrong, and a record you cannot correct
/// is a record that slowly stops matching what was said.
///
/// Edits go through `AppState.editTranscriptLine`, which puts the correction in the
/// durable record too — see `TranscriptEdit`. System notes are not editable: they are
/// the app's own account of what it did, and a rewritable one would be worthless.
struct TranscriptView: View {
    var items: [TranscriptItem]
    /// Drawn on the column itself, not just in the header, so the state is visible while
    /// reading rather than only while looking at the controls.
    var pinned: Bool = false
    var onEdit: (UUID, String) -> Void = { _, _ in }
    var onDelete: (UUID) -> Void = { _ in }
    /// Draws the conversation without the scroll view around it.
    ///
    /// Only `SettingsSnapshot` passes this, for the same reason `SettingsView` has it:
    /// `ImageRenderer` walks the tree with no window behind it, a `ScrollView` in that
    /// situation lays its content against an unspecified proposal and renders as an empty
    /// rectangle, and a snapshot of an empty rectangle is worse than no snapshot. Every
    /// row is built up front too — a `LazyVStack` never builds anything offscreen.
    var flattened: Bool = false

    /// The line being rewritten, if any. Held here rather than per row so that opening
    /// a second editor closes the first — two half-finished corrections is a way to lose
    /// one of them.
    @State private var editingID: UUID?
    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        if flattened {
            VStack(alignment: .leading, spacing: 16) { rowStack }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            scrolling
        }
    }

    private var scrolling: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                rows
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            .onChange(of: items.count) { _, _ in
                // Never while a correction is open: scrolling the editor out from under
                // somebody mid-sentence is how a half-typed fix gets abandoned.
                guard editingID == nil else { return }
                withAnimation(.easeOut(duration: 0.28)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
            // Following the LAST line's text was only right while every line was appended
            // in arrival order. A line now goes where its timestamp says, so the line
            // being written into is often not the last one — a system note lands under a
            // reply that is still streaming — and the view stopped following mid-sentence.
            // What it actually needs to follow is however much text exists in total.
            .onChange(of: writtenLength) { _, _ in
                guard editingID == nil else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
        }
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 16) { rowStack }
    }

    @ViewBuilder
    private var rowStack: some View {
        Color.clear.frame(height: 2)
        if pinned { pinnedBadge }
        ForEach(items) { item in
            row(item).id(item.id)
        }
        Color.clear.frame(height: 8).id("BOTTOM")
    }

    /// Says the state and what it buys, in the column it applies to. "Pinned" alone
    /// would be a word next to an icon; the second half is the reason somebody pinned it.
    private var pinnedBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "pin.fill")
                .font(.system(size: 8.5))
                .rotationEffect(.degrees(45))
            Text("PINNED")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.0)
            Text("kept until you unpin it")
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(Theme.accentInk.opacity(0.75))
        }
        .foregroundStyle(Theme.accentInk)
        .padding(.horizontal, 8).padding(.vertical, 3.5)
        .background(Capsule().fill(Theme.accent.opacity(0.14))
            .overlay(Capsule().stroke(Theme.accent.opacity(0.3), lineWidth: 1)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Transcript pinned — kept until you unpin it")
    }

    private func beginEditing(_ item: TranscriptItem) {
        guard item.speaker != .system else { return }
        editingID = item.id
        draft = item.text
        editorFocused = true
    }

    private func commitEdit() {
        guard let id = editingID else { return }
        onEdit(id, draft)
        editingID = nil
        draft = ""
    }

    private func cancelEdit() {
        editingID = nil
        draft = ""
    }

    /// The editor a line turns into. Deliberately the same width and position as the
    /// text it replaces, so correcting a line does not move the conversation around it.
    private func editor(for item: TranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $draft)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .frame(minHeight: 46, maxHeight: 160)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.accent.opacity(0.45), lineWidth: 1)))
                .accessibilityLabel("Edit this line")

            HStack(spacing: 8) {
                Button("Save") { commitEdit() }
                    .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Cancel") { cancelEdit() }
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
                Text("⌘↩ saves · esc cancels")
                    .font(.system(size: 9.5)).foregroundStyle(Theme.textFaint)
            }
        }
    }

    /// Total characters on screen. Changes on every delta of whichever line is being
    /// written into, wherever it sits.
    private var writtenLength: Int {
        items.reduce(0) { $0 + $1.text.count }
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
                    Text(isUser ? "YOU" : "FLOW")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(isUser ? Theme.accentInk : Theme.voiceInk)
                    // The same dot for both halves of the same idea: a line that is
                    // still being filled in. The assistant's fills in from the left as it
                    // speaks; the user's is a row that exists before its words do, put
                    // there the moment they stop talking so their turn never appears
                    // below the reply to it.
                    if item.streaming || item.pending {
                        Circle().fill(isUser ? Theme.accentInk : Theme.voiceInk)
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
                    Thumbnail(image: img, title: item.text, captured: item.at)
                }
                if editingID == item.id {
                    editor(for: item)
                } else if item.pending && item.text.isEmpty {
                    // Not a spinner and not a guess at what they said — just the shape of
                    // a line that is coming, so the turn holds its place in the order.
                    Text("transcribing…")
                        .font(.system(size: 12, design: .rounded))
                        .italic()
                        .foregroundStyle(Theme.textFaint.opacity(0.75))
                } else if item.unheard {
                    // Said, not heard. Kept rather than deleted: the reply underneath it
                    // is about whatever this was, and removing the row would leave an
                    // answer to a question nobody appears to have asked.
                    Text(item.text)
                        .font(.system(size: 12, design: .rounded))
                        .italic()
                        .foregroundStyle(Theme.textFaint.opacity(0.75))
                } else if !item.text.isEmpty {
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
            // Nothing here is destructive by accident: a double-click opens an editor,
            // and deleting is behind the right-click menu with the word "Delete" on it.
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { beginEditing(item) }
            .contextMenu {
                Button("Edit line") { beginEditing(item) }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.text, forType: .string)
                }
                Divider()
                Button("Delete line", role: .destructive) { onDelete(item.id) }
            }
            .help("Double-click to correct this line. It stays here — and in the saved "
                  + "transcript — until you delete it.")
        }
    }
}

/// A frame in the transcript, and the way into the full-size one.
///
/// The tile is cropped to fill at 92 points, which is a deliberate choice for the column
/// — every frame is the same height, so the conversation does not lurch around a
/// screenshot — but it means the thumbnail is genuinely not readable. Clicking it opens
/// the whole capture over the screen. The affordance is spelled out on hover rather than
/// left to be discovered: nothing else in this column is clickable, so there is no reason
/// to assume this is.
private struct Thumbnail: View {
    var image: NSImage
    var title: String
    var captured: Date

    @State private var hovering = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(height: 92)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if hovering {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 8.5, weight: .semibold))
                        Text("View")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3.5)
                    .background(Capsule().fill(.black.opacity(0.62)))
                    .padding(6)
                    .transition(.opacity)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(hovering ? Theme.accent.opacity(0.75) : Theme.hairlineHi, lineWidth: 1))
            // The clipped rectangle, not the uncropped image: without this the hit area
            // is the frame's full aspect ratio and clicks land on rows above and below.
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture { open() }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.14), value: hovering)
            .help("Click to see this frame full size")
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title.isEmpty ? "Screen frame" : title)
            .accessibilityHint("Opens the frame full size")
            .accessibilityAction { open() }
    }

    private func open() {
        ScreenshotPreview.show(image, title: title, captured: captured)
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
