import Foundation

/// What a recording is called on disk.
///
/// This used to be four lines inside `SessionRecorder.start`, which was fine while there
/// was exactly one kind of output. There are now four — audio, screen, camera, both — and
/// two writers that have to agree on the name, so the rule lives here where it can be
/// stated once and tested.
///
/// THE CONSTRAINTS, and why each one is here:
///
///  * **`/` and `:` become `-`.** `/` is the path separator, so a title containing one
///    would silently write into a subdirectory that does not exist. `:` is the *classic*
///    Mac path separator: APFS accepts it, but Finder renders it as `/` and some
///    round-trips through older APIs still swap the two. Both are replaced rather than
///    stripped, so "9:30 standup" stays legible as "9-30 standup".
///  * **Newlines and other control characters become spaces.** Titles can come from the
///    model (see `SessionTitle`), and a file name with a newline in it is a file nobody
///    can type at a shell and Finder shows with a stray glyph.
///  * **A leading `.` is dropped.** A dot-file is invisible in Finder, so "Open in
///    Finder" would open a folder that appears not to contain the recording.
///  * **Forty characters of title, at most.** The full name is stamp + separator + title
///    + extension; the stamp is 16, so this keeps the whole thing comfortably inside the
///    255-byte limit even when the title is emoji at four bytes each.
///  * **The stamp always comes first.** It is what makes the folder sort chronologically
///    in Finder, which is how anyone actually finds a recording from last Tuesday.
///
/// The extension is decided by the capture mode, never by the title: `.wav` for
/// audio-only — unchanged from every build before video existed, so existing recordings
/// and the code that scans for them keep working — and `.mov` for anything with pictures
/// in it.
public enum RecordingName {

    /// Sortable, sub-minute-free, and legal on every filesystem macOS will mount.
    /// Seconds are deliberately absent: two recordings in the same minute is rare, and
    /// the name is something people read far more often than they disambiguate.
    public static let stampFormat = "yyyy-MM-dd HH.mm"

    /// How much of the title survives, in characters — the limit that decides how the
    /// name *reads*.
    public static let titleLimit = 40

    /// And the same limit in bytes, which is the one the filesystem actually enforces.
    ///
    /// Both are needed. APFS counts 255 *bytes*, not characters, and a title of emoji
    /// runs to seven bytes each once the variation selectors are counted — so forty
    /// characters can be 280 bytes, and the write fails with a name that looks short.
    /// 180 leaves comfortable room for the stamp (16), the separator (5) and the
    /// extension (4).
    public static let titleByteLimit = 180

    /// What separates the stamp from the title. An em dash with spaces around it, so the
    /// two halves stay readable when the name is truncated in the middle by a table.
    public static let separator = " — "

    public static func stamp(_ date: Date, timeZone: TimeZone? = nil) -> String {
        let f = DateFormatter()
        // Fixed locale: with the user's own, an Arabic or Thai locale would number the
        // file with digits that do not sort next to the others in the same folder.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = stampFormat
        if let timeZone { f.timeZone = timeZone }
        return f.string(from: date)
    }

    /// The title, made safe to put in a file name. May come back empty.
    public static func sanitize(_ title: String) -> String {
        var out = ""
        for ch in title {
            if ch == "/" || ch == ":" {
                out.append("-")
            } else if ch.isNewline || (ch.unicodeScalars.first.map { CharacterSet.controlCharacters.contains($0) } ?? false) {
                out.append(" ")
            } else {
                out.append(ch)
            }
        }
        // Truncate first, then trim: cutting at 40 characters can leave a trailing space,
        // and a file name ending in a space is legal, invisible and maddening.
        out = String(out.prefix(titleLimit))
        // Then again by bytes, one whole character at a time — slicing a UTF-8 sequence
        // in the middle would produce a name the filesystem rejects outright.
        while out.utf8.count > titleByteLimit { out.removeLast() }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasPrefix(".") { out.removeFirst() }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The name without an extension.
    public static func base(title: String, date: Date, timeZone: TimeZone? = nil) -> String {
        let safe = sanitize(title)
        let s = stamp(date, timeZone: timeZone)
        return safe.isEmpty ? s : s + separator + safe
    }

    /// The whole thing, extension and all.
    public static func fileName(title: String,
                                date: Date,
                                mode: CaptureMode,
                                timeZone: TimeZone? = nil) -> String {
        base(title: title, date: date, timeZone: timeZone) + "." + mode.fileExtension
    }

    /// Every extension the recordings folder can legitimately contain.
    ///
    /// The library scan filters on this rather than on `wav` alone — which is what it did
    /// when audio was the only output, and which would have made every video recording
    /// invisible in Settings the day one was written.
    public static let knownExtensions: Set<String> = ["wav", "mov"]

    /// True for a file the recordings list should show.
    public static func isRecording(_ url: URL) -> Bool {
        knownExtensions.contains(url.pathExtension.lowercased())
    }
}
