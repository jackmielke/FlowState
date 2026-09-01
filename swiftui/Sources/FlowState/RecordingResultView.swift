import SwiftUI
import AppKit
import QuickLookThumbnailing
import FlowStateCore

/// The panel a finished recording leaves behind.
///
/// It replaces a line of transcript that named a file and then scrolled away. The three
/// things anyone wants in the ten seconds after a recording stops are to know it worked,
/// to hear it, and to find it — so the card says what was written, how long it runs, how
/// big it is and which folder it went to, and both actions are one click.
///
/// The same card is used on the stage, where it is a result that has just happened and
/// can be waved away, and in Settings, where it is a standing record of the last output.
/// One view rather than two, so the two cannot drift into saying different things about
/// the same file.
struct RecordingResultCard: View {
    let file: RecordingFile
    /// What the card is: a thing that just happened, or the standing latest output.
    var title = "Recording saved"
    /// What the last attempt to open or play it could not do, or nil when the file is
    /// exactly where the card says it is.
    var problem: String?
    var onPlay: () -> Void
    var onReveal: () -> Void
    /// Nil where the card is a fixture rather than a dismissible result.
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            RecordingThumbnail(url: file.url)

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.good)
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.text)
                    }
                    // The whole name, extension and all: the name is how the file is
                    // found again next week, and half a name is not a name. Selectable
                    // because the other way people move a path around is by copying it.
                    Text(file.fileName)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(file.summary)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textFaint)
                    Text(file.folderLabel())
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
                // Read as one sentence rather than four fragments — "2:14" alone is
                // announced as a time of day, and "· 6.4 MB · WAV" as punctuation.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title + ". " + file.accessibilityLabel)
                .accessibilityValue("Saved in \(file.folderLabel())")

                if let problem { RecordingProblemLine(message: problem) }

                HStack(spacing: 8) {
                    Button { onPlay() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill").font(.system(size: 9.5))
                            Text("Play")
                        }
                    }
                    .buttonStyle(GhostButtonStyle(tint: Theme.accentInk, padH: 11, padV: 6))
                    .accessibilityLabel("Play")
                    .accessibilityHint("Plays \(file.fileName)")
                    .help("Play \(file.fileName)")

                    Button { onReveal() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "folder").font(.system(size: 10))
                            Text("Open in Finder")
                        }
                    }
                    .buttonStyle(GhostButtonStyle(padH: 11, padV: 6))
                    .accessibilityLabel("Open in Finder")
                    .accessibilityHint("Shows \(file.fileName) in Finder")
                    .help("Show \(file.fileName) in Finder")
                }
                .padding(.top, 1)
            }

            Spacer(minLength: 4)

            if let onDismiss {
                Button { onDismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textFaint)
                .accessibilityLabel("Dismiss")
                .accessibilityHint("Hides this panel. The recording is kept.")
                .help("Dismiss — the recording is kept")
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.good.opacity(0.10))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.good.opacity(0.28), lineWidth: 1)))
        .accessibilityElement(children: .contain)
    }
}

/// A picture of the recording, when the system can make one, and an honest placeholder
/// when it cannot.
///
/// This asks QuickLook rather than hard-coding a glyph, because QuickLook is what knows:
/// it renders a waveform for an audio file and a poster frame for a video, so the day the
/// recorder writes something with pictures in it the card shows the pictures, with no
/// second code path to remember to add.
///
/// Until it answers — and for a file that has been deleted, and on any Mac where the
/// generator declines — the tile is a waveform mark on the panel fill. The file is named
/// in full beside it either way, which is the part that actually identifies it.
struct RecordingThumbnail: View {
    let url: URL
    var width: CGFloat = 64
    var height: CGFloat = 46

    @State private var image: NSImage?

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 7, style: .continuous) }

    var body: some View {
        ZStack {
            shape.fill(Theme.fill)
            if let image {
                // Fit rather than fill: QuickLook hands back a square mark for an audio
                // file, and cropping a quarter off each side of it to fill a 64×46 tile
                // loses the part that says what kind of file this is. A video poster
                // frame letterboxes instead, which is the cheaper mistake of the two.
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay(shape.stroke(Theme.hairlineHi, lineWidth: 1))
        // Decorative: everything it conveys is in the card's own label, and a second
        // announcement of the same file is noise in a screen reader, not information.
        .accessibilityHidden(true)
        .task(id: url) {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            image = await Self.thumbnail(for: url, size: CGSize(width: width, height: height), scale: scale)
        }
    }

    private static func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        // Asking about a file that is not there is a slow way to be told nil.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

extension SessionRecorder.Recording {
    /// The same file, described the way the result panel needs it.
    ///
    /// The bridge lives here rather than on `Recording` itself because
    /// `SessionRecorder.swift` imports nothing but Foundation, AVFoundation, Combine and
    /// os — that is what lets `Scripts/verify-recorder.sh` compile it on its own — and
    /// `import FlowStateCore` would end that.
    var described: RecordingFile {
        RecordingFile(url: url, seconds: seconds, bytes: bytes)
    }
}

/// "That click could not do what it said, and here is why."
///
/// Every place a recording can be opened from gets one of these, because every one of
/// them can be clicked on a file that is no longer there — and a button that silently
/// does nothing is the failure this whole path exists to stop.
struct RecordingProblemLine: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.badInk)
                .padding(.top, 1.5)
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Problem. " + message)
    }
}
