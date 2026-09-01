import XCTest
import CoreGraphics
@testable import FlowStateCore

final class HUDDragTests: XCTestCase {

    // MARK: - click vs drag

    func testAPerfectlyStillPressIsAClick() {
        XCTAssertTrue(HUDDrag.isClick(translation: .zero))
    }

    func testAHandShakeIsStillAClick() {
        // What a real click off a trackpad looks like. If this is a drag, the widget
        // slides away every time somebody tries to start a session from the orb.
        XCTAssertTrue(HUDDrag.isClick(translation: CGSize(width: 2, height: -1)))
    }

    func testAnActualDragIsNotAClick() {
        XCTAssertFalse(HUDDrag.isClick(translation: CGSize(width: 40, height: 12)))
    }

    func testDiagonalSlopCountsTheHypotenuseNotTheAxes() {
        // 3 across and 3 down is 4.24 away, not 3. Measuring per-axis would call this a
        // click, and diagonal is the direction a hand drifts most.
        XCTAssertFalse(HUDDrag.isClick(translation: CGSize(width: 3, height: 3)))
    }

    // MARK: - where it lands

    func testDraggingRightAndDownMovesTheWindowRightAndDown() {
        // The y flip: SwiftUI's downward drag is AppKit's decreasing y. Backwards here
        // and the widget runs away from the pointer.
        let moved = HUDDrag.origin(from: CGPoint(x: 100, y: 500),
                                   translation: CGSize(width: 30, height: 40))
        XCTAssertEqual(moved.x, 130)
        XCTAssertEqual(moved.y, 460)
    }

    // MARK: - staying reachable

    func testAWidgetDraggedOffTheRightEdgeIsPulledBack() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 100, height: 100)
        let origin = HUDDrag.clamped(CGPoint(x: 3000, y: 400), size: size, in: screen)
        XCTAssertEqual(origin.x, 1340)
    }

    func testBleedLetsItTuckPartlyOffTheEdgeOnPurpose() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 100, height: 100)
        let origin = HUDDrag.clamped(CGPoint(x: -900, y: 400), size: size,
                                     in: screen, bleed: 60)
        XCTAssertEqual(origin.x, -60)
    }

    func testClampingSurvivesAWindowLargerThanTheScreen() {
        // maxX < minX here. Without the inner max() this returns an origin below the
        // screen's own minimum and the widget vanishes off the left.
        let screen = CGRect(x: 0, y: 0, width: 200, height: 200)
        let size = CGSize(width: 400, height: 400)
        let origin = HUDDrag.clamped(CGPoint(x: 50, y: 50), size: size, in: screen)
        XCTAssertEqual(origin.x, 0)
        XCTAssertEqual(origin.y, 0)
    }

    // MARK: - snapping

    func testNearTheLeftEdgeSnapsLeft() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 6, y: 400, width: 100, height: 100)
        XCTAssertEqual(HUDDrag.snapEdge(for: frame, in: screen), .left)
    }

    func testNearTheRightEdgeSnapsRight() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 1330, y: 400, width: 100, height: 100)
        XCTAssertEqual(HUDDrag.snapEdge(for: frame, in: screen), .right)
    }

    func testTheMiddleOfTheScreenSnapsToNothing() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 700, y: 400, width: 100, height: 100)
        XCTAssertNil(HUDDrag.snapEdge(for: frame, in: screen))
    }

    func testBeingNearTheTopIsNotAnEdgeWorthSnappingTo() {
        // Vertical proximity is usually somebody moving past the menu bar, not putting
        // the widget away. Snapping there fights them.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 700, y: 795, width: 100, height: 100)
        XCTAssertNil(HUDDrag.snapEdge(for: frame, in: screen))
    }
}
