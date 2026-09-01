import XCTest
import CoreGraphics
@testable import FlowStateCore

/// The rule the caption strip and the floating widget both follow: be on the screen
/// being worked on, or be nowhere.
final class ActiveScreenOverlayTests: XCTestCase {

    // MARK: - Which screen

    func testOffWhenDisabled() {
        XCTAssertNil(ActiveScreenOverlay.target(enabled: false, active: 1, attached: [1, 2]))
    }

    func testFollowsTheActiveScreen() {
        XCTAssertEqual(ActiveScreenOverlay.target(enabled: true, active: 2, attached: [1, 2]), 2)
        XCTAssertEqual(ActiveScreenOverlay.target(enabled: true, active: 1, attached: [1, 2]), 1)
    }

    /// The whole point: with two screens and no idea which one is being used, the
    /// transcript stays off rather than landing on the wrong one.
    func testUnresolvedWithSeveralScreensStaysOff() {
        XCTAssertNil(ActiveScreenOverlay.target(enabled: true, active: nil, attached: [1, 2]))
    }

    /// One screen has no wrong answer, so an unresolved pointer is not a reason to
    /// withhold the overlay. Most Macs are this case.
    func testUnresolvedWithOneScreenUsesIt() {
        XCTAssertEqual(ActiveScreenOverlay.target(enabled: true, active: nil, attached: [7]), 7)
    }

    /// A display the watcher settled on before it was unplugged is not somewhere to put
    /// a caption.
    func testActiveScreenThatWentAwayStaysOff() {
        XCTAssertNil(ActiveScreenOverlay.target(enabled: true, active: 9, attached: [1, 2]))
        // …but with only one left, that one wins.
        XCTAssertEqual(ActiveScreenOverlay.target(enabled: true, active: 9, attached: [1]), 1)
    }

    func testNoScreensAtAllStaysOff() {
        XCTAssertNil(ActiveScreenOverlay.target(enabled: true, active: 1, attached: []))
    }

    // MARK: - Where on it

    /// Bottom-right of a small screen is bottom-right of a big one, at the same inset —
    /// not a point somewhere in from it.
    func testKeepsItsCornerAcrossScreenSizes() {
        let laptop = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let big    = CGRect(x: 1440, y: 0, width: 3840, height: 2160)
        let widget = CGRect(x: 1440 - 120 - 24, y: 24, width: 120, height: 48)   // bottom-right

        let moved = ActiveScreenOverlay.moved(widget, from: laptop, to: big)
        XCTAssertEqual(moved.x, big.maxX - widget.width - 24)
        XCTAssertEqual(moved.y, big.minY + 24)
    }

    func testKeepsTheOppositeCornerToo() {
        let a = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let b = CGRect(x: -2560, y: 200, width: 2560, height: 1440)
        let widget = CGRect(x: 24, y: 900 - 48 - 24, width: 120, height: 48)     // top-left

        let moved = ActiveScreenOverlay.moved(widget, from: a, to: b)
        XCTAssertEqual(moved.x, b.minX + 24)
        XCTAssertEqual(moved.y, b.maxY - widget.height - 24)
    }

    /// Nothing in this app parks an overlay in the middle of a screen, so the middle is
    /// not preserved — the nearer edge is. Pinned here so the trade-off is deliberate
    /// rather than discovered.
    func testMiddleIsNotPreserved() {
        let a = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let b = CGRect(x: 0, y: 0, width: 2000, height: 2000)
        let widget = CGRect(x: 450, y: 450, width: 100, height: 100)

        let moved = ActiveScreenOverlay.moved(widget, from: a, to: b)
        XCTAssertEqual(moved, CGPoint(x: 450, y: 450))
    }

    /// Whatever the anchoring says, the result is on the screen it moved to.
    func testMovedResultIsAlwaysOnTheNewScreen() {
        let a = CGRect(x: 0, y: 0, width: 400, height: 300)
        let b = CGRect(x: 5000, y: -1000, width: 1280, height: 800)
        for x in stride(from: CGFloat(0), through: 300, by: 37) {
            for y in stride(from: CGFloat(0), through: 200, by: 41) {
                let origin = ActiveScreenOverlay.moved(CGRect(x: x, y: y, width: 100, height: 60),
                                                       from: a, to: b)
                XCTAssertGreaterThanOrEqual(origin.x, b.minX)
                XCTAssertGreaterThanOrEqual(origin.y, b.minY)
                XCTAssertLessThanOrEqual(origin.x + 100, b.maxX)
                XCTAssertLessThanOrEqual(origin.y + 60, b.maxY)
            }
        }
    }

    // MARK: - Clamping

    func testClampPullsAStrandedOverlayBack() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let stranded = CGRect(x: 3000, y: -400, width: 120, height: 48)
        let origin = ActiveScreenOverlay.clamped(stranded, in: visible)
        XCTAssertEqual(origin.x, 1440 - 120 - ActiveScreenOverlay.inset)
        XCTAssertEqual(origin.y, ActiveScreenOverlay.inset)
    }

    func testClampLeavesSomethingAlreadyInside() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fine = CGRect(x: 300, y: 400, width: 120, height: 48)
        XCTAssertEqual(ActiveScreenOverlay.clamped(fine, in: visible), CGPoint(x: 300, y: 400))
    }

    /// An overlay bigger than the screen cannot honour both insets — it pins to the near
    /// edge rather than producing a negative-slack origin off the other side.
    func testOverlayWiderThanTheScreenPinsToTheNearEdge() {
        let visible = CGRect(x: 100, y: 50, width: 200, height: 100)
        let huge = CGRect(x: -900, y: -900, width: 900, height: 900)
        let origin = ActiveScreenOverlay.clamped(huge, in: visible)
        XCTAssertEqual(origin.x, visible.minX + ActiveScreenOverlay.inset)
        XCTAssertEqual(origin.y, visible.minY + ActiveScreenOverlay.inset)
    }

    func testOriginsAreWholePoints() {
        let visible = CGRect(x: 0.5, y: 0.5, width: 1439.5, height: 899.5)
        let origin = ActiveScreenOverlay.clamped(CGRect(x: -10, y: -10, width: 120, height: 48), in: visible)
        XCTAssertEqual(origin.x, origin.x.rounded())
        XCTAssertEqual(origin.y, origin.y.rounded())
    }
}
