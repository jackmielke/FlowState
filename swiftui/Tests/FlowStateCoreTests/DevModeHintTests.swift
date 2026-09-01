import XCTest
@testable import FlowStateCore

final class DevModeHintTests: XCTestCase {

    private func offer(devModeOn: Bool = false,
                       dismissed: Bool = false,
                       turns: Int = 0,
                       said: String? = nil) -> DevModeHint.Trigger? {
        DevModeHint.offer(devModeOn: devModeOn, dismissed: dismissed,
                          assistantTurns: turns, lastUserTranscript: said)
    }

    func test_askingForCodeWorkOffersImmediately() {
        XCTAssertEqual(offer(said: "hey can you fix the spacing on that button"),
                       .askedForCodeWork(phrase: "can you fix"))
        XCTAssertEqual(offer(said: "add a toggle in my repo for dark mode"),
                       .askedForCodeWork(phrase: "in my repo"))
    }

    func test_ordinaryConversationDoesNotTriggerEarly() {
        for said in ["what's on my calendar today",
                     "what am I looking at",
                     "tell me a joke"] {
            XCTAssertNil(offer(turns: 1, said: said), said)
        }
    }

    func test_offeredOnceSomeoneHasActuallySettledIn() {
        XCTAssertNil(offer(turns: 2))
        XCTAssertEqual(offer(turns: 3), .settledIn)
    }

    /// The whole point: a "not now" is permanent, and it never appears when Dev Mode is
    /// already on. Nagging about an unused feature is worse than silence.
    func test_neverOffersWhenOnOrAfterDismissal() {
        XCTAssertNil(offer(devModeOn: true, turns: 99, said: "can you fix the build"))
        XCTAssertNil(offer(dismissed: true, turns: 99, said: "can you fix the build"))
    }

    func test_copyAdaptsToWhetherClaudeCodeIsInstalled() {
        let t = DevModeHint.Trigger.settledIn
        XCTAssertTrue(t.body(claudeReady: true).contains("your own Claude account"))
        XCTAssertTrue(t.body(claudeReady: false).contains("npm install"))
    }
}
