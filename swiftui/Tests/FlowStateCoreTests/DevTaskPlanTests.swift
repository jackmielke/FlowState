import XCTest
@testable import FlowStateCore

final class DevTaskPlanTests: XCTestCase {

    // MARK: - What kind of job this is

    func test_ordinaryWorkGetsTheMiddleOfTheRoadPlan() {
        let p = DevTaskPlan.plan(for: "add a keyboard shortcut for muting the microphone")
        XCTAssertEqual(p.shape, .medium)
        XCTAssertEqual(p.model, "sonnet")
        XCTAssertNil(p.effort)
    }

    func test_aCosmeticEditIsSmall() {
        for said in ["fix the typo in the welcome sheet",
                     "tighten the padding on that button",
                     "change the colour of the badge to red"] {
            XCTAssertEqual(DevTaskPlan.plan(for: said).shape, .small, said)
            XCTAssertEqual(DevTaskPlan.plan(for: said).effort, "low", said)
        }
    }

    /// The length guard. A sentence can name a small change and still be a big job.
    func test_aLongInstructionIsNotSmallJustBecauseItSaysRename() {
        let said = "rename the orb view, then pull the whole settings pane apart so each "
                 + "tab owns its own file, and make the transcript scroll properly again"
        XCTAssertNotEqual(DevTaskPlan.plan(for: said).shape, .small)
    }

    func test_thinkingWorkGetsTheBigModel() {
        for said in ["why does the orb stutter when the backdrop is on?",
                     "refactor the capture path so the tap is owned in one place",
                     "investigate the memory leak in the recorder"] {
            let p = DevTaskPlan.plan(for: said)
            XCTAssertEqual(p.shape, .large, said)
            XCTAssertEqual(p.model, "opus", said)
            XCTAssertEqual(p.effort, "high", said)
        }
    }

    /// An overloaded big model must degrade rather than stall a conversation that is
    /// waiting out loud for an answer.
    func test_theBigModelAlwaysHasSomethingToFallBackTo() {
        XCTAssertEqual(DevTaskPlan.plan(for: "refactor the audio engine").fallbackModel, "sonnet")
    }

    // MARK: - Questions

    func test_aQuestionAboutTheCodeIsReadOnly() {
        let p = DevTaskPlan.plan(for: "where is the caption bar's font size set?")
        XCTAssertEqual(p.shape, .question)
        XCTAssertEqual(p.tools, ["Read", "Grep", "Glob"])
        XCTAssertEqual(p.effort, "low")
    }

    /// "Show me" is a question opener, but not when what follows is a change.
    func test_aQuestionShapedRequestForAChangeIsStillAChange() {
        let p = DevTaskPlan.plan(for: "show me a tighter layout — make the rows shorter")
        XCTAssertNotEqual(p.shape, .question)
        XCTAssertNil(p.tools)
    }

    // MARK: - MCP

    /// The measured win: five MCP servers connect before the first token, which costs
    /// about three seconds on this Mac. Nothing in an ordinary edit needs them.
    func test_anOrdinaryTaskDoesNotWaitForMCPServers() {
        XCTAssertFalse(DevTaskPlan.plan(for: "fix the typo in the welcome sheet").loadsMCP)
    }

    func test_aTaskThatNamesAConnectorWaitsForThem() {
        for said in ["put the release notes in Notion",
                     "post the summary to slack",
                     "check the supabase schema and add the missing column"] {
            XCTAssertTrue(DevTaskPlan.plan(for: said).loadsMCP, said)
        }
    }

    /// The escape hatch, for a repo whose tasks need a connector the words never name.
    func test_turningFastStartOffAlwaysLoadsThem() {
        XCTAssertTrue(DevTaskPlan.plan(for: "fix the typo", fastStart: false).loadsMCP)
    }

    func test_theSummaryIsReadable() {
        XCTAssertEqual(DevTaskPlan.plan(for: "fix the typo").summary, "sonnet · low · no mcp")
    }
}
