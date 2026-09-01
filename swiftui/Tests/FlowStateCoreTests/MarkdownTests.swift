import XCTest
@testable import FlowStateCore

final class MarkdownTests: XCTestCase {

    // MARK: - Inline

    /// The bug this whole type exists for: `**done**` shown as five literal asterisks.
    func test_boldIsFormattingNotPunctuation() {
        XCTAssertEqual(Markdown.plain("that's **done** now"), "that's done now")
        XCTAssertEqual(Markdown.plain("_quietly_ and `exactly`"), "quietly and exactly")
        XCTAssertEqual(Markdown.plain("see [the docs](https://example.com)"), "see the docs")
    }

    func test_textWithNoMarkdownSurvivesUntouched() {
        let spoken = "I moved the button 4px left and rebuilt it."
        XCTAssertEqual(Markdown.plain(spoken), spoken)
        XCTAssertTrue(Markdown.isPlain(spoken))
    }

    /// Multiplication, arithmetic and shell globs are not emphasis.
    func test_looseAsterisksAreLeftAlone() {
        XCTAssertEqual(Markdown.plain("2 * 3 * 4"), "2 * 3 * 4")
        XCTAssertEqual(Markdown.plain("rm *.tmp"), "rm *.tmp")
    }

    /// A streaming turn is half-written for a second or two, and "**bo" must not flash
    /// as asterisks before its closing pair arrives.
    func test_aHalfWrittenBoldSpanIsClosedWhileStreaming() {
        XCTAssertEqual(Markdown.closingDanglingMarkers("it is **do"), "it is **do**")
        XCTAssertEqual(Markdown.closingDanglingMarkers("run `swift bu"), "run `swift bu`")
        XCTAssertEqual(Markdown.closingDanglingMarkers("it is **done**"), "it is **done**")
        XCTAssertEqual(Markdown.plain("it is **do"), "it is **do", "only while streaming")
    }

    // MARK: - Blocks

    func test_paragraphsJoinSoftWrappedLinesAndSplitOnBlankOnes() {
        let out = Markdown.blocks("one line\nwrapped onto two\n\nsecond paragraph")
        XCTAssertEqual(out, [.paragraph("one line wrapped onto two"),
                             .paragraph("second paragraph")])
    }

    func test_listsAreListsAndNestingIsKept() {
        let out = Markdown.blocks("""
        - first
        - second
          - nested
        1. one
        2) two
        """)
        XCTAssertEqual(out, [.bullet(text: "first", depth: 0),
                             .bullet(text: "second", depth: 0),
                             .bullet(text: "nested", depth: 1),
                             .numbered(marker: "1.", text: "one", depth: 0),
                             .numbered(marker: "2)", text: "two", depth: 0)])
    }

    /// The distinction a naive parser gets wrong, and the reason bullets require the
    /// space: emphasis at the start of a line is not a list item.
    func test_emphasisAtTheStartOfALineIsNotABullet() {
        XCTAssertEqual(Markdown.blocks("**done** — the build is green"),
                       [.paragraph("**done** — the build is green")])
        XCTAssertEqual(Markdown.blocks("*emphasis* leads this line"),
                       [.paragraph("*emphasis* leads this line")])
    }

    func test_headingsNeedTheirSpace() {
        XCTAssertEqual(Markdown.blocks("## What changed"),
                       [.heading(level: 2, text: "What changed")])
        XCTAssertEqual(Markdown.blocks("#hashtag"), [.paragraph("#hashtag")])
    }

    func test_fencedCodeIsKeptVerbatim() {
        let out = Markdown.blocks("""
        before
        ```swift
        let x = 1
          let y = 2
        ```
        after
        """)
        XCTAssertEqual(out, [.paragraph("before"),
                             .code(language: "swift", text: "let x = 1\n  let y = 2"),
                             .paragraph("after")])
    }

    /// A reply that is still arriving is mid-fence for as long as the snippet takes.
    func test_anUnterminatedFenceStillRendersWhatItHasSoFar() {
        XCTAssertEqual(Markdown.blocks("```\nlet x = 1"),
                       [.code(language: nil, text: "let x = 1")])
    }

    func test_quotesAndRules() {
        XCTAssertEqual(Markdown.blocks("> quoted\n\n---"),
                       [.quote("quoted"), .rule])
    }

    /// A dash on its own line is a bullet with nothing in it, not a horizontal rule.
    func test_aSingleDashIsNotARule() {
        XCTAssertEqual(Markdown.blocks("-"), [.paragraph("-")])
        XCTAssertEqual(Markdown.blocks("- - -"), [.rule])
    }

    /// Tables get no renderer, but their rows must not collapse into one run-on
    /// paragraph — which is what joining soft-wrapped lines would do to them.
    func test_tableRowsStayOnTheirOwnLinesAndTheDividerGoes() {
        let out = Markdown.blocks("""
        | file | change |
        |------|--------|
        | Orb.swift | tightened |
        """)
        XCTAssertEqual(out, [.paragraph("file  ·  change"),
                             .paragraph("Orb.swift  ·  tightened")])
    }

    func test_tabsIndentTheSameAsSpaces() {
        XCTAssertEqual(Markdown.blocks("- top\n\t- nested"),
                       [.bullet(text: "top", depth: 0),
                        .bullet(text: "nested", depth: 2)])
    }

    func test_deepNestingCannotPushTextOffTheSideOfTheSidebar() {
        let deep = String(repeating: " ", count: 40) + "- far in"
        XCTAssertEqual(Markdown.blocks(deep), [.bullet(text: "far in", depth: 3)])
    }

    func test_emptyInputIsNoBlocksRatherThanOneEmptyOne() {
        XCTAssertTrue(Markdown.blocks("").isEmpty)
        XCTAssertTrue(Markdown.blocks("\n\n   \n").isEmpty)
    }
}
