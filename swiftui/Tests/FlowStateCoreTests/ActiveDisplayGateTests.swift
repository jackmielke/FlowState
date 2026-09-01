import XCTest
@testable import FlowStateCore

final class ActiveDisplayGateTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// The case the gate exists for: dragging a window across the shared edge puts the
    /// pointer on the far screen for a moment. That must not move anything.
    func testAGlancingCrossingIsIgnored() {
        var g = ActiveDisplayGate(active: 1)
        XCTAssertNil(g.observe(2, at: at(0)))
        XCTAssertNil(g.observe(2, at: at(0.2)))
        XCTAssertNil(g.observe(1, at: at(0.3)))
        XCTAssertEqual(g.active, 1)
    }

    func testHoldingStillOnTheOtherScreenSwitches() {
        var g = ActiveDisplayGate(active: 1)
        XCTAssertNil(g.observe(2, at: at(0)))
        XCTAssertNil(g.observe(2, at: at(0.4)))
        XCTAssertEqual(g.observe(2, at: at(0.5)), 2)
        XCTAssertEqual(g.active, 2)
    }

    /// A switch is reported once, not on every sample after it.
    func testTheChangeIsReportedOnlyOnce() {
        var g = ActiveDisplayGate(active: 1)
        _ = g.observe(2, at: at(0))
        XCTAssertEqual(g.observe(2, at: at(1)), 2)
        XCTAssertNil(g.observe(2, at: at(2)))
        XCTAssertNil(g.observe(2, at: at(3)))
    }

    /// Bouncing between two screens must not accumulate toward a switch.
    func testAlternatingNeverSettles() {
        var g = ActiveDisplayGate(active: 1)
        for i in 0..<20 {
            XCTAssertNil(g.observe(i.isMultiple(of: 2) ? 2 : 3, at: at(Double(i) * 0.4)))
        }
        XCTAssertEqual(g.active, 1)
    }

    /// The pointer leaves every screen mid-transition. That is not a display.
    func testPointerOffAllScreensHoldsTheCurrentOne() {
        var g = ActiveDisplayGate(active: 1)
        XCTAssertNil(g.observe(2, at: at(0)))
        XCTAssertNil(g.observe(nil, at: at(0.3)))
        // The candidate was dropped, so the clock restarts rather than carrying over.
        XCTAssertNil(g.observe(2, at: at(0.6)))
        XCTAssertEqual(g.observe(2, at: at(1.2)), 2)
    }

    func testAdoptSkipsTheWait() {
        var g = ActiveDisplayGate(active: 1)
        g.adopt(7)
        XCTAssertEqual(g.active, 7)
        XCTAssertNil(g.observe(7, at: at(10)))
    }
}
