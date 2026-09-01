import Foundation

/// A finished recording, as the result panel has to describe it.
///
/// The old contract was a sentence in the transcript — "Saved 2026-08-21 22.40 — standup
/// .wav · 2:14" — which is true, scrolls away in four turns, and cannot be clicked. The
/// panel that replaced it needs more than that sentence: the whole file name, how long it
/// runs, how big it is, which folder it landed in, and something for VoiceOver to read
/// that is not a monospaced blob of separators.
///
/// All of that is derived from three facts — the path, the length and the byte count — so
/// it is derived here rather than in the view. The card, the Settings list and anything
/// that comes later then say the same thing about the same file, and the saying of it is
/// testable, which it is not once it is interpolated into a `Text`.
///
/// It deliberately knows nothing about whether the file is still on disk. That is a
/// question about the moment somebody clicks, not about the moment the recording stopped,
/// and it is answered by `RecordingLocation`.
public struct RecordingFile: Equatable, Identifiable, Sendable {
    public var id: String { url.path }

    /// The final output path — the one the app hands to Finder.
    public let url: URL
    public let seconds: TimeInterval
    /// Zero when the size is not known yet, which happens when the panel is built from
    /// the stop outcome before the directory scan has caught up.
    public let bytes: Int

    public init(url: URL, seconds: TimeInterval, bytes: Int = 0) {
        self.url = url
        self.seconds = seconds
        self.bytes = bytes
    }

    /// `2026-08-21 22.40 — standup.wav`. Shown in full, extension and all: the name is
    /// how the file is found again a week later, so a truncated one is barely a name.
    public var fileName: String { url.lastPathComponent }

    /// What the recording is *of*, rather than what it is stored as.
    public var title: String { url.deletingPathExtension().lastPathComponent }

    /// `WAV`, `MOV`, whatever it actually is — read off the path rather than hard-coded,
    /// so this does not quietly start lying the day the recorder learns a second format.
    public var formatLabel: String { url.pathExtension.uppercased() }

    public var lengthLabel: String { Self.length(seconds) }

    /// Nil rather than "0 bytes" when the size is not known — a metadata line is allowed
    /// to be short, but not to state something false about the file.
    public var sizeLabel: String? { bytes > 0 ? Self.size(bytes) : nil }

    /// The line under the file name: `2:14 · 6.2 MB · WAV`.
    public var summary: String {
        [lengthLabel, sizeLabel, formatLabel.isEmpty ? nil : formatLabel]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The containing folder with the home directory folded back to `~`. A recording
    /// lives six levels down inside Application Support, and the full path is both too
    /// long for the card and less recognisable than the abbreviated one.
    public func folderLabel(home: String = NSHomeDirectory()) -> String {
        let folder = url.deletingLastPathComponent().path
        guard !home.isEmpty, folder == home || folder.hasPrefix(home + "/") else { return folder }
        return "~" + folder.dropFirst(home.count)
    }

    /// One sentence for VoiceOver, because the visual card is a glyph, a truncated name
    /// and a row of separator-joined numbers — none of which survives being read aloud.
    public var accessibilityLabel: String {
        var parts = ["Recording \(title)", Self.spokenLength(seconds)]
        if let sizeLabel { parts.append(sizeLabel) }
        if !formatLabel.isEmpty { parts.append("\(formatLabel) file") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Formatting

    /// `8s` under a minute, `2:14` over it — the same shape the live recording clock in
    /// the header uses, so the number does not change format when the recording stops.
    public static func length(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The same length as words. "2:14" is read by VoiceOver as a time of day.
    public static func spokenLength(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60, rest = total % 60
        func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }
        if minutes == 0 { return plural(rest, "second") }
        if rest == 0 { return plural(minutes, "minute") }
        return plural(minutes, "minute") + " " + plural(rest, "second")
    }

    /// Decimal units, deliberately: this number sits next to a button that opens Finder,
    /// and Finder counts a megabyte as a million bytes. Being 4.9% more accurate than the
    /// window the user is about to look at is not accuracy.
    public static func size(_ bytes: Int) -> String {
        let b = max(0, bytes)
        if b < 1_000 { return "\(b) bytes" }
        let units = ["kB", "MB", "GB", "TB"]
        // The first division has already happened by the time the loop is entered, so
        // `unit` indexes kB from the start rather than a byte unit that is not in the list.
        var value = Double(b) / 1_000, unit = 0
        while value >= 1_000, unit < units.count - 1 { value /= 1_000; unit += 1 }
        // One decimal until it stops adding information: "998 MB" beats "997.6 MB".
        return value >= 100
            ? String(format: "%.0f %@", value, units[unit])
            : String(format: "%.1f %@", value, units[unit])
    }
}

/// Where "Open in Finder" should actually land.
///
/// `NSWorkspace.activateFileViewerSelecting` is happy to be handed a path to a file that
/// is not there. It does nothing at all, silently, which from the user's side is
/// indistinguishable from a dead button — and a recording that has been moved, renamed or
/// dragged to the Trash since the panel was drawn is the ordinary case, not an exotic one.
///
/// So the decision of what to open is made here, out of the way of AppKit, and every
/// route into Finder in the app goes through it: the result panel, a row in the Settings
/// list, and the button under that list. The three then behave the same when the file is
/// gone, which is the only time the difference between them would ever have shown up.
public enum RecordingLocation {

    public enum Target: Equatable, Sendable {
        /// Reveal the file, selected, in the folder that holds it.
        case selectFile(URL)
        /// The file is not there — but the folder is, and it is still the useful place
        /// to be sent. Anything else the user was looking for is in it.
        case openFolder(URL)
        /// Nothing to open. The caller should say so rather than appear to have worked.
        case nothing
    }

    public struct Resolution: Equatable, Sendable {
        public let target: Target
        /// What to tell the user, or nil when the file was exactly where it should be.
        /// A problem does not always mean nothing happened — a moved file still opens
        /// its folder, and still says why that is not what was asked for.
        public let problem: String?

        public init(target: Target, problem: String?) {
            self.target = target
            self.problem = problem
        }
    }

    /// - Parameters:
    ///   - file: the recording to reveal, or nil when there is not one to reveal.
    ///   - folder: where recordings are kept, or nil if even that is unknown.
    ///   - exists: asked about each candidate, so this stays decidable in a test.
    public static func resolve(file: URL?,
                               folder: URL?,
                               exists: (URL) -> Bool) -> Resolution {
        let folderIsThere = folder.map(exists) ?? false

        guard let file else {
            // No file named at all: the button is a "take me to my recordings" button,
            // and that is not an error unless the folder has never been made.
            guard let folder, folderIsThere else {
                return Resolution(target: .nothing,
                                  problem: "There are no recordings yet — nothing has been saved to disk.")
            }
            return Resolution(target: .openFolder(folder), problem: nil)
        }

        if exists(file) { return Resolution(target: .selectFile(file), problem: nil) }

        let name = file.lastPathComponent
        guard let folder, folderIsThere else {
            return Resolution(target: .nothing,
                              problem: "\(name) is no longer on disk, and neither is the folder it was saved to.")
        }
        return Resolution(
            target: .openFolder(folder),
            problem: "\(name) has been moved, renamed or deleted since it was recorded — opening the folder it was saved to instead.")
    }
}
