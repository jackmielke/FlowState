import XCTest
@testable import FlowStateCore

/// The paths that can destroy a file.
///
/// A wrong answer from the model costs a retry. A failed revert costs the file — so
/// these check the disk afterwards rather than trusting the return value.
final class QuickEditApplyTests: XCTestCase {

    private var dir: String!
    private var path: String!
    private let original = """
    import Foundation

    enum Widget {
        static let maxItems = 10
        static let color = "blue"
    }

    """

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "quickedit-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        path = dir + "/Widget.swift"
        try original.write(toFile: path, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func onDisk() -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<missing>"
    }

    // MARK: - the good case

    func testAValidEditIsWrittenAndTheOriginalIsKept() {
        let edited = original.replacingOccurrences(of: "maxItems = 10", with: "maxItems = 25")
        let r = QuickEdit.apply(reply: edited, to: path, original: original,
                                runCheck: { _ in nil })       // parses fine
        XCTAssertTrue(r.ok)
        XCTAssertTrue(onDisk().contains("maxItems = 25"))
        XCTAssertEqual(r.backup, path + ".flowstate-backup")
        XCTAssertEqual(try? String(contentsOfFile: r.backup!, encoding: .utf8), original)
    }

    func testFencedRepliesStillLandCorrectly() {
        let edited = original.replacingOccurrences(of: "\"blue\"", with: "\"green\"")
        let r = QuickEdit.apply(reply: "```swift\n" + edited + "\n```", to: path,
                                original: original, runCheck: { _ in nil })
        XCTAssertTrue(r.ok)
        XCTAssertTrue(onDisk().contains("\"green\""))
    }

    // MARK: - the case this exists for

    func testAnEditThatDoesNotParseIsRolledBack() {
        // The model drops a brace. Without the revert this leaves a file that will not
        // build, discovered minutes later by something unrelated.
        let broken = original.replacingOccurrences(of: "}", with: "")
        let r = QuickEdit.apply(reply: broken, to: path, original: original,
                                runCheck: { _ in "error: expected '}'" })
        XCTAssertFalse(r.ok)
        XCTAssertEqual(onDisk(), original, "the original must be back on disk byte for byte")
        XCTAssertTrue(r.detail.contains("put the file back"))
    }

    func testARolledBackEditLeavesNoStrayBackupBehind() {
        let broken = original.replacingOccurrences(of: "}", with: "")
        _ = QuickEdit.apply(reply: broken, to: path, original: original,
                            runCheck: { _ in "error" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".flowstate-backup"),
                       "a reverted edit should not leave a backup of a file that never changed")
    }

    func testATruncatedReplyToALongFileIsRefusedBeforeAnythingIsWritten() throws {
        // The length rule only engages above 400 characters, so this is what it is for:
        // a big file coming back half-length is a truncated generation, and the write
        // should not happen at all.
        let long = original + String(repeating: "// filler line\n", count: 40)
        try long.write(toFile: path, atomically: true, encoding: .utf8)
        var checked = false
        let r = QuickEdit.apply(reply: "import Foundation\n\nenum Wid", to: path,
                                original: long, runCheck: { _ in checked = true; return nil })
        XCTAssertFalse(r.ok)
        XCTAssertFalse(checked, "a refusal should happen before anything is written")
        XCTAssertEqual(onDisk(), long)
    }

    func testATruncatedReplyToAShortFileIsCaughtByTheParserInstead() {
        // Below 400 characters, halving a file is a plausible edit rather than evidence
        // of truncation — so the length rule deliberately stays out of the way and the
        // second layer does the work. Worth pinning down: it means a short file DOES get
        // written before it is judged, and the revert is what protects it.
        let r = QuickEdit.apply(reply: "import Foundation\n\nenum Wid", to: path,
                                original: original,
                                runCheck: { _ in "error: expected '{'" })
        XCTAssertFalse(r.ok)
        XCTAssertEqual(onDisk(), original, "the parser's revert must restore it exactly")
    }

    func testAnUnchangedReplyIsNotWritten() {
        let r = QuickEdit.apply(reply: original, to: path, original: original,
                                runCheck: { _ in nil })
        XCTAssertFalse(r.ok)
        XCTAssertEqual(onDisk(), original)
    }

    // MARK: - the checker itself

    func testAMissingCheckerIsNoOpinionRatherThanFailure() {
        // env exits non-zero when the command does not exist, but a Markdown file with no
        // parser installed must not be treated as broken code.
        XCTAssertNil(QuickEdit.shellCheck(["definitely-not-a-real-binary-9f3a"]))
    }

    func testTheRealCheckerCatchesRealBrokenSwift() throws {
        try "enum A { static let x = ".write(toFile: path, atomically: true, encoding: .utf8)
        let out = QuickEdit.shellCheck(QuickEdit.syntaxCheck(for: path)!)
        XCTAssertNotNil(out, "swiftc -parse should reject an unterminated declaration")
    }

    func testTheRealCheckerPassesRealValidSwift() {
        let out = QuickEdit.shellCheck(QuickEdit.syntaxCheck(for: path)!)
        XCTAssertNil(out, "the fixture is valid Swift and must not be flagged")
    }
}
