import XCTest
@testable import FlowStateCore

/// What the result panel says about a finished recording, and where its one button goes
/// when the file underneath it has been moved out from under the panel.
final class RecordingFileTests: XCTestCase {

    private let folder = URL(fileURLWithPath: "/Users/x/Library/Application Support/FlowState/Recordings",
                             isDirectory: true)

    private func file(_ name: String = "2026-08-21 22.40 — standup.wav",
                      seconds: TimeInterval = 134,
                      bytes: Int = 6_432_000) -> RecordingFile {
        RecordingFile(url: folder.appendingPathComponent(name), seconds: seconds, bytes: bytes)
    }

    // MARK: - What the card says

    func test_theWholeFileNameIsTheName_extensionIncluded() {
        XCTAssertEqual(file().fileName, "2026-08-21 22.40 — standup.wav")
        XCTAssertEqual(file().title, "2026-08-21 22.40 — standup")
    }

    func test_theMetadataLineIsLengthSizeAndFormat() {
        XCTAssertEqual(file().summary, "2:14 · 6.4 MB · WAV")
    }

    /// The format is read off the path, so the day this records something other than a
    /// WAV the card is already right about it.
    func test_theFormatComesFromTheFileItself() {
        XCTAssertEqual(file("screen.mov").formatLabel, "MOV")
    }

    /// A size of zero means "not scanned yet", not "an empty file", and the card would
    /// rather say less than say something false.
    func test_anUnknownSizeIsLeftOutRatherThanReportedAsZero() {
        let f = RecordingFile(url: folder.appendingPathComponent("a.wav"), seconds: 8, bytes: 0)
        XCTAssertNil(f.sizeLabel)
        XCTAssertEqual(f.summary, "8s · WAV")
    }

    func test_lengthIsSecondsUnderAMinuteAndAClockOverIt() {
        XCTAssertEqual(RecordingFile.length(0), "0s")
        XCTAssertEqual(RecordingFile.length(8.4), "8s")
        XCTAssertEqual(RecordingFile.length(59.4), "59s")
        XCTAssertEqual(RecordingFile.length(60), "1:00")
        XCTAssertEqual(RecordingFile.length(134), "2:14")
        XCTAssertEqual(RecordingFile.length(3_725), "62:05")
    }

    /// Finder counts a megabyte as a million bytes, and this number sits next to a button
    /// that opens Finder.
    func test_sizesAreCountedTheWayFinderCountsThem() {
        XCTAssertEqual(RecordingFile.size(0), "0 bytes")
        XCTAssertEqual(RecordingFile.size(999), "999 bytes")
        XCTAssertEqual(RecordingFile.size(1_000), "1.0 kB")
        XCTAssertEqual(RecordingFile.size(6_432_000), "6.4 MB")
        XCTAssertEqual(RecordingFile.size(998_000_000), "998 MB")
        XCTAssertEqual(RecordingFile.size(2_500_000_000), "2.5 GB")
    }

    func test_aNegativeSizeIsNotRenderedAsANegativeNumber() {
        XCTAssertEqual(RecordingFile.size(-1), "0 bytes")
        XCTAssertEqual(RecordingFile.length(-4), "0s")
    }

    // MARK: - What VoiceOver hears

    /// "2:14" is read aloud as a time of day, and "6.4 MB · WAV" as punctuation.
    func test_theSpokenLabelIsASentenceRatherThanTheVisualLine() {
        XCTAssertEqual(file().accessibilityLabel,
                       "Recording 2026-08-21 22.40 — standup, 2 minutes 14 seconds, 6.4 MB, WAV file")
    }

    func test_spokenLengthsAreCountedInWordsAndPluralised() {
        XCTAssertEqual(RecordingFile.spokenLength(0), "0 seconds")
        XCTAssertEqual(RecordingFile.spokenLength(1), "1 second")
        XCTAssertEqual(RecordingFile.spokenLength(44), "44 seconds")
        XCTAssertEqual(RecordingFile.spokenLength(60), "1 minute")
        XCTAssertEqual(RecordingFile.spokenLength(61), "1 minute 1 second")
        XCTAssertEqual(RecordingFile.spokenLength(134), "2 minutes 14 seconds")
    }

    // MARK: - Where the folder is

    func test_theFolderIsShownRelativeToHome() {
        XCTAssertEqual(file().folderLabel(home: "/Users/x"),
                       "~/Library/Application Support/FlowState/Recordings")
    }

    /// A different user's home is not a prefix to be stripped — folding it anyway would
    /// print a path that does not exist.
    func test_aPathOutsideHomeIsShownWhole() {
        let f = RecordingFile(url: URL(fileURLWithPath: "/Volumes/Audio/take.wav"), seconds: 3)
        XCTAssertEqual(f.folderLabel(home: "/Users/x"), "/Volumes/Audio")
        XCTAssertEqual(file().folderLabel(home: "/Users/xavier"),
                       "/Users/x/Library/Application Support/FlowState/Recordings")
    }

    // MARK: - Where "Open in Finder" goes

    func test_aFileThatIsThereIsRevealedSelected() {
        let target = folder.appendingPathComponent("standup.wav")
        let r = RecordingLocation.resolve(file: target, folder: folder, exists: { _ in true })
        XCTAssertEqual(r.target, .selectFile(target))
        XCTAssertNil(r.problem)
    }

    /// The case the button used to fail silently on: AppKit is perfectly happy to be
    /// handed a path to a file that is not there, and does nothing at all about it.
    func test_aFileThatHasBeenMovedOpensItsFolderAndSaysSo() {
        let gone = folder.appendingPathComponent("standup.wav")
        let r = RecordingLocation.resolve(file: gone, folder: folder,
                                          exists: { $0 != gone })
        XCTAssertEqual(r.target, .openFolder(folder))
        XCTAssertEqual(r.problem?.contains("standup.wav"), true)
        XCTAssertEqual(r.problem?.contains("moved, renamed or deleted"), true)
    }

    func test_withNeitherFileNorFolderThereIsNothingToOpen() {
        let r = RecordingLocation.resolve(file: folder.appendingPathComponent("standup.wav"),
                                          folder: folder, exists: { _ in false })
        XCTAssertEqual(r.target, .nothing)
        XCTAssertEqual(r.problem?.contains("neither is the folder"), true)
    }

    /// "Show my recordings" with nothing recorded yet is a request, not a fault — as long
    /// as there is a folder to show.
    func test_noFileNamedJustOpensTheFolder() {
        let r = RecordingLocation.resolve(file: nil, folder: folder, exists: { _ in true })
        XCTAssertEqual(r.target, .openFolder(folder))
        XCTAssertNil(r.problem)
    }

    func test_noFileAndNoFolderIsReportedRatherThanDoingNothing() {
        let r = RecordingLocation.resolve(file: nil, folder: folder, exists: { _ in false })
        XCTAssertEqual(r.target, .nothing)
        XCTAssertEqual(r.problem, "There are no recordings yet — nothing has been saved to disk.")
    }

    func test_anUnknownFolderIsNotTreatedAsOne() {
        let r = RecordingLocation.resolve(file: nil, folder: nil, exists: { _ in true })
        XCTAssertEqual(r.target, .nothing)
        XCTAssertNotNil(r.problem)
    }
}
