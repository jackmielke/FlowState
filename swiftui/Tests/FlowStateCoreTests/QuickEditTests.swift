import XCTest
@testable import FlowStateCore

final class QuickEditTests: XCTestCase {

    private let file = String(repeating: "let x = 1\n", count: 60)   // 600 chars

    // MARK: - getting the file back out

    func testAPlainReplyIsTheFile() {
        XCTAssertEqual(QuickEdit.extract("let a = 1\nlet b = 2"), "let a = 1\nlet b = 2")
    }

    func testFencesComeOffEvenThoughWeAskedForNone() {
        // Models fence code however firmly you ask them not to, and failing a good edit
        // over three backticks would be a silly way to lose one.
        XCTAssertEqual(QuickEdit.extract("```swift\nlet a = 1\n```"), "let a = 1")
    }

    func testBareFencesComeOffToo() {
        XCTAssertEqual(QuickEdit.extract("```\nlet a = 1\n```"), "let a = 1")
    }

    func testBackticksInsideTheCodeSurvive() {
        let src = "let doc = \"\"\"\nuse ```swift for code\n\"\"\""
        XCTAssertEqual(QuickEdit.extract(src), src)
    }

    // MARK: - refusing to write nonsense

    func testAGoodEditPasses() {
        XCTAssertNil(QuickEdit.check(original: file, edited: file + "let y = 2\n"))
    }

    func testAnEmptyReplyIsRefused() {
        XCTAssertEqual(QuickEdit.check(original: file, edited: "   \n "), .empty)
    }

    func testAnIdenticalReplyIsNotWritten() {
        XCTAssertEqual(QuickEdit.check(original: file, edited: file), .unchanged)
    }

    func testTrailingWhitespaceAloneCountsAsUnchanged() {
        XCTAssertEqual(QuickEdit.check(original: file, edited: file + "\n\n"), .unchanged)
    }

    func testAHalfFileIsRefusedAsTruncated() {
        // The failure this exists to prevent: a generation that stopped early, written
        // over working code. It looks like a successful edit right up until you read it.
        let half = String(file.prefix(file.count / 2 - 20))
        guard case .suspiciouslyShort = QuickEdit.check(original: file, edited: half) else {
            return XCTFail("a half-length rewrite should be refused")
        }
    }

    func testShortFilesAreNotHeldToTheLengthRule() {
        // In a ten-line file, halving it is a plausible edit rather than a truncation.
        let tiny = "let a = 1\nlet b = 2\n"
        XCTAssertNil(QuickEdit.check(original: tiny, edited: "let a = 1\n"))
    }

    func testAFileTooBigForTheFastLaneIsRefusedBeforeAnythingIsSent() {
        let huge = String(repeating: "x", count: QuickEdit.maxBytes + 1)
        guard case .tooLarge = QuickEdit.check(original: huge, edited: "y") else {
            return XCTFail("an oversized file should be refused")
        }
    }

    // MARK: - proving it parses

    func testSwiftGetsAParseCheck() {
        XCTAssertEqual(QuickEdit.syntaxCheck(for: "/tmp/A.swift")?.first, "swiftc")
    }

    func testPythonGetsOne() {
        XCTAssertEqual(QuickEdit.syntaxCheck(for: "/tmp/a.py")?.first, "python3")
    }

    func testAnExtensionWithNoCheapCheckIsAllowedThrough() {
        // Refusing to edit a README for want of a parser would be worse than not checking.
        XCTAssertNil(QuickEdit.syntaxCheck(for: "/tmp/README.md"))
    }

    func testTheCheckIsCaseInsensitiveAboutExtensions() {
        XCTAssertEqual(QuickEdit.syntaxCheck(for: "/tmp/A.SWIFT")?.first, "swiftc")
    }

    // MARK: - the prompt

    func testThePromptCarriesTheTaskThePathAndTheFile() {
        let p = QuickEdit.prompt(task: "make it a toggle", path: "Hotkey.swift", contents: "let a = 1")
        XCTAssertTrue(p.contains("make it a toggle"))
        XCTAssertTrue(p.contains("Hotkey.swift"))
        XCTAssertTrue(p.contains("let a = 1"))
    }

    func testThePromptTellsItToBailRatherThanGuess() {
        // The fast lane's worst outcome is not refusing — it is a confident wrong edit
        // to a file that needed a change somewhere else too.
        let p = QuickEdit.prompt(task: "t", path: "p", contents: "c")
        XCTAssertTrue(p.lowercased().contains("unchanged rather than guessing"))
    }
}
