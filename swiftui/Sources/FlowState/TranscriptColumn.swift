import SwiftUI
import FlowStateCore

/// The transcript, and the two things that can be true of it other than "here it is":
/// it is hidden, or there is nothing in it yet.
///
/// Its own view rather than a branch inside the sidebar for one reason: this is the part
/// of the app whose whole promise is that it does not disappear, and the states where it
/// *appears* to have disappeared are exactly the ones worth being able to look at. As a
/// named view it can be rendered on its own by `SettingsSnapshot` — pinned, hidden, empty
/// and full, in both colour schemes — without a window, a socket or a microphone.
struct TranscriptColumn: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack {
            if state.settings.transcriptHidden {
                hidden
            } else {
                TranscriptView(items: state.transcript,
                               pinned: state.transcriptIsPinned,
                               onEdit: { id, text in state.editTranscriptLine(id, to: text) },
                               onDelete: { id in state.deleteTranscriptLine(id) })
                if state.transcript.count <= 1 { empty }
            }
        }
    }

    /// Before anything has been said. Says what will land here and — the part people do
    /// not expect from a voice app — that it will still be here tomorrow.
    private var empty: some View {
        VStack(spacing: 7) {
            Image(systemName: "waveform")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(Theme.textFaint.opacity(0.5))
            Text("Nothing said yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textFaint)
            Text("Your words and FlowState's replies land here as you\ntalk, and stay here after a restart.")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textFaint.opacity(0.7))
        }
        .allowsHitTesting(false)
        .padding(.bottom, 40)
    }

    /// What "hide" leaves behind.
    ///
    /// A blank column would be indistinguishable from a transcript that had been wiped,
    /// which is exactly the fear this feature exists to avoid — so it says how many lines
    /// are still there, that recording carried on, and where the way back is. Hiding is
    /// for screen shares; it is not a privacy control and does not pretend to be one.
    private var hidden: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(Theme.textFaint.opacity(0.55))
            Text("Transcript hidden")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textFaint)
            Text("\(state.transcript.count) line\(state.transcript.count == 1 ? "" : "s") still here"
                 + (state.settings.privacy.persistToDisk ? ", still being saved." : ".")
                 + "\nNothing was deleted.")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textFaint.opacity(0.75))
            Button("Show transcript") { state.toggleTranscriptHidden() }
                .buttonStyle(GhostButtonStyle(tint: Theme.accentInk))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 30)
        .accessibilityElement(children: .contain)
    }
}
