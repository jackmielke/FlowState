import XCTest
@testable import FlowStateCore

final class SlowToolTests: XCTestCase {

    func test_onlyToolsThatLeaveTheMachineAreRacedAgainstAClock() {
        XCTAssertTrue(SlowToolPolicy.canBeSlow("web_search"))
        XCTAssertTrue(SlowToolPolicy.canBeSlow("notion_read"))
        XCTAssertFalse(SlowToolPolicy.canBeSlow("read_clipboard"))
        XCTAssertFalse(SlowToolPolicy.canBeSlow("get_context"))
        XCTAssertFalse(SlowToolPolicy.canBeSlow("go_to_sleep"))
    }

    func test_networkToolsGetTheTighterBudget() {
        XCTAssertLessThan(SlowToolPolicy.budget(for: "web_search"),
                          SlowToolPolicy.budget(for: "read_clipboard"))
    }

    /// The holding line exists to stop the model filling the gap with an invented
    /// answer, which is worse than the silence it replaces.
    func test_theHoldingNoteForbidsGuessing() {
        let note = SlowToolPolicy.holdingNote(for: "web_search").lowercased()
        XCTAssertTrue(note.contains("not guess") || note.contains("do not guess"))
        XCTAssertTrue(note.contains("new message"))
    }

    // MARK: - Learning which tools are slow

    func test_aToolIsNotJudgedOnOneBadCall() {
        let book = ToolLatencyBook()
        book.record("notion_read", seconds: 6)
        XCTAssertFalse(book.expectsSlow("notion_read", budget: 1.8),
                       "one slow call is an anecdote, and the first call of a session pays "
                       + "for the TLS handshake")
    }

    func test_twoSlowCallsChangeTheAppsMind() {
        let book = ToolLatencyBook()
        book.record("notion_read", seconds: 6)
        book.record("notion_read", seconds: 6)
        XCTAssertTrue(book.expectsSlow("notion_read", budget: 1.8))
    }

    func test_gettingFastAgainIsBelieved() {
        let book = ToolLatencyBook()
        for _ in 0..<2 { book.record("web_search", seconds: 8) }
        XCTAssertTrue(book.expectsSlow("web_search", budget: 1.8))
        for _ in 0..<8 { book.record("web_search", seconds: 0.4) }
        XCTAssertFalse(book.expectsSlow("web_search", budget: 1.8))
    }

    func test_aLocalToolIsNeverCalledSlowHoweverItBehaves() {
        let book = ToolLatencyBook()
        for _ in 0..<5 { book.record("read_clipboard", seconds: 30) }
        XCTAssertFalse(book.expectsSlow("read_clipboard", budget: 1.8))
    }

    func test_theAverageLeansOnWhatHappenedLately() {
        let book = ToolLatencyBook()
        book.record("web_search", seconds: 3)
        book.record("web_search", seconds: 0)
        XCTAssertEqual(book.expected("web_search")!, 2.0, accuracy: 0.001)
        XCTAssertEqual(book.callCount("web_search"), 2)
        XCTAssertNil(book.expected("never_run"))
    }

    func test_nonsenseSamplesAreIgnored() {
        let book = ToolLatencyBook()
        book.record("web_search", seconds: -1)
        book.record("web_search", seconds: .nan)
        XCTAssertNil(book.expected("web_search"))
    }
}
