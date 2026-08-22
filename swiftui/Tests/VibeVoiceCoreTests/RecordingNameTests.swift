import XCTest
@testable import VibeVoiceCore

/// What a recording is called.
///
/// Every one of these is a bug that has shipped in some recorder somewhere: a title with
/// a slash in it writing into a directory that does not exist, a title with a colon that
/// Finder renders as a slash, a dot-file the user cannot see, a name so long the write
/// fails at 255 bytes, and a locale that numbers the file in digits that do not sort next
/// to its neighbours.
final class RecordingNameTests: XCTestCase {

    private let when = Date(timeIntervalSince1970: 1_770_000_000)   // 2026-02-02 02:40 UTC
    private let utc = TimeZone(identifier: "UTC")!

    private func stamp() -> String { RecordingName.stamp(when, timeZone: utc) }

    // MARK: - The stamp

    func test_stampIsSortableAndMinuteResolution() {
        XCTAssertEqual(stamp(), "2026-02-02 02.40")
    }

    /// The stamp must sort lexicographically the way it sorts chronologically — that is
    /// the entire reason it leads the name.
    func test_stampsSortInTimeOrder() {
        let earlier = RecordingName.stamp(when, timeZone: utc)
        let later = RecordingName.stamp(when.addingTimeInterval(3600), timeZone: utc)
        XCTAssertLessThan(earlier, later)
    }

    /// No `/` and no `:` in the stamp itself, whatever the format is changed to.
    func test_stampIsFilesystemSafe() {
        XCTAssertFalse(stamp().contains("/"))
        XCTAssertFalse(stamp().contains(":"))
    }

    // MARK: - Sanitising the title

    func test_pathSeparatorsBecomeHyphens() {
        XCTAssertEqual(RecordingName.sanitize("9:30 standup"), "9-30 standup")
        XCTAssertEqual(RecordingName.sanitize("docs/spec"), "docs-spec")
        // Both at once, and neither is dropped — the name stays readable.
        XCTAssertEqual(RecordingName.sanitize("a/b:c"), "a-b-c")
    }

    /// A title from the model can contain a newline. A file name with one in it cannot be
    /// typed at a shell and shows a stray glyph in Finder.
    func test_newlinesAndControlCharactersBecomeSpaces() {
        XCTAssertEqual(RecordingName.sanitize("two\nlines"), "two lines")
        XCTAssertEqual(RecordingName.sanitize("tab\there"), "tab here")
    }

    /// A leading dot makes the file invisible, so "Open in Finder" would land in a folder
    /// that appears not to contain the recording.
    func test_leadingDotsAreDropped() {
        XCTAssertEqual(RecordingName.sanitize(".hidden"), "hidden")
        XCTAssertEqual(RecordingName.sanitize("...hidden"), "hidden")
        // A dot anywhere else is fine — "v1.2 review" is a legitimate title.
        XCTAssertEqual(RecordingName.sanitize("v1.2 review"), "v1.2 review")
    }

    func test_titleIsTruncatedAndLeavesNoTrailingSpace() {
        let long = String(repeating: "a", count: 30) + " " + String(repeating: "b", count: 30)
        let safe = RecordingName.sanitize(long)
        XCTAssertLessThanOrEqual(safe.count, RecordingName.titleLimit)
        // Truncating at 40 characters lands on the space; a file name ending in a space
        // is legal, invisible and maddening.
        XCTAssertFalse(safe.hasSuffix(" "), safe)
    }

    /// Four bytes a character is the worst case, and it still has to fit in 255 bytes
    /// with the stamp, the separator and the extension.
    func test_worstCaseNameFitsTheFilesystemLimit() {
        let emoji = String(repeating: "🎙️", count: 200)
        let name = RecordingName.fileName(title: emoji, date: when, mode: .full, timeZone: utc)
        XCTAssertLessThan(name.utf8.count, 255, "\(name.utf8.count) bytes")
    }

    func test_emptyOrWhitespaceTitleLeavesJustTheStamp() {
        XCTAssertEqual(RecordingName.base(title: "", date: when, timeZone: utc), stamp())
        XCTAssertEqual(RecordingName.base(title: "   \n ", date: when, timeZone: utc), stamp())
    }

    // MARK: - The whole name

    func test_stampComesFirstSoTheFolderSortsChronologically() {
        let name = RecordingName.base(title: "standup", date: when, timeZone: utc)
        XCTAssertTrue(name.hasPrefix(stamp()), name)
        XCTAssertEqual(name, "2026-02-02 02.40 — standup")
    }

    /// The one thing that must not change: audio-only recordings keep the extension, the
    /// shape and the folder they have always had.
    func test_audioOnlyIsStillAWavNamedExactlyAsBefore() {
        XCTAssertEqual(RecordingName.fileName(title: "standup", date: when, mode: .audioOnly, timeZone: utc),
                       "2026-02-02 02.40 — standup.wav")
    }

    func test_everyVideoModeWritesAMov() {
        for mode in CaptureMode.allCases where mode.isVideo {
            let name = RecordingName.fileName(title: "demo", date: when, mode: mode, timeZone: utc)
            XCTAssertTrue(name.hasSuffix(".mov"), "\(mode.rawValue) → \(name)")
        }
    }

    /// The extension comes from the mode, never from the title — otherwise a title
    /// ending in ".wav" would produce "….wav.mov" or, worse, be treated as already
    /// having one.
    func test_titleEndingInAnExtensionDoesNotChangeTheRealOne() {
        let name = RecordingName.fileName(title: "notes.wav", date: when, mode: .audioScreen, timeZone: utc)
        XCTAssertTrue(name.hasSuffix(".mov"), name)
    }

    // MARK: - The library scan

    /// The scan filtered on `wav` alone while audio was the only output. Left that way,
    /// every video recording would be written correctly and then be invisible in Settings.
    func test_theLibraryRecognisesBothOutputs() {
        XCTAssertTrue(RecordingName.isRecording(URL(fileURLWithPath: "/tmp/a.wav")))
        XCTAssertTrue(RecordingName.isRecording(URL(fileURLWithPath: "/tmp/a.mov")))
        XCTAssertTrue(RecordingName.isRecording(URL(fileURLWithPath: "/tmp/a.MOV")), "case is not meaningful on APFS")
        XCTAssertFalse(RecordingName.isRecording(URL(fileURLWithPath: "/tmp/a.txt")))
        XCTAssertFalse(RecordingName.isRecording(URL(fileURLWithPath: "/tmp/a")))
    }

    /// Every mode's extension is one the scan will show. A mode that writes a file the
    /// library cannot see is the same bug as above, arriving by a different door.
    func test_everyModeProducesAFileTheLibraryWillList() {
        for mode in CaptureMode.allCases {
            XCTAssertTrue(RecordingName.knownExtensions.contains(mode.fileExtension),
                          "\(mode.rawValue) writes .\(mode.fileExtension), which the library ignores")
        }
    }
}
