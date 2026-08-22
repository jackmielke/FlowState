import XCTest
import CoreGraphics
@testable import VibeVoiceCore

final class CameraOverlayTests: XCTestCase {

    private let frame = CGSize(width: 1920, height: 1080)

    /// The complaint this type answers: a circle on screen, a square in the file. The
    /// first half of parity is that the region is square, so a circular mask is round.
    func testInsetIsSquareSoTheMaskIsACircle() {
        let r = CameraOverlay(size: .medium).rect(in: frame)
        XCTAssertEqual(r.width, r.height, accuracy: 0.001)
        XCTAssertEqual(r.width, 1920 * 0.20, accuracy: 0.001)
    }

    /// Bottom-left origin. A corner that is wrong in y is the failure that hides longest,
    /// because three of the four cases still look plausible.
    func testEveryCornerLandsInsideTheFrameAndOnTheRightSide() {
        let margin = 1920 * CameraOverlay.marginFraction
        for corner in CameraCorner.allCases {
            let r = CameraOverlay(size: .small, corner: corner).rect(in: frame)
            XCTAssertTrue(CGRect(origin: .zero, size: frame).contains(r), "\(corner) escapes the frame")
            switch corner {
            case .bottomLeading:
                XCTAssertEqual(r.minX, margin, accuracy: 0.001); XCTAssertEqual(r.minY, margin, accuracy: 0.001)
            case .bottomTrailing:
                XCTAssertEqual(r.maxX, 1920 - margin, accuracy: 0.001); XCTAssertEqual(r.minY, margin, accuracy: 0.001)
            case .topLeading:
                XCTAssertEqual(r.minX, margin, accuracy: 0.001); XCTAssertEqual(r.maxY, 1080 - margin, accuracy: 0.001)
            case .topTrailing:
                XCTAssertEqual(r.maxX, 1920 - margin, accuracy: 0.001); XCTAssertEqual(r.maxY, 1080 - margin, accuracy: 0.001)
            }
        }
    }

    func testFullFillsTheFrameExactly() {
        let r = CameraOverlay(size: .full).rect(in: frame)
        XCTAssertEqual(r, CGRect(origin: .zero, size: frame))
    }

    func testSizesAreOrderedAndDistinct() {
        let widths = [CameraSize.small, .medium, .large, .full].map { $0.frameFraction }
        XCTAssertEqual(widths, widths.sorted())
        XCTAssertEqual(Set(widths).count, widths.count)
    }

    /// Where the user parked the bubble is which corner the recording uses.
    func testNearestCornerFollowsTheBubble() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(CameraOverlay.nearestCorner(to: CGPoint(x: 40, y: 40), in: screen), .bottomLeading)
        XCTAssertEqual(CameraOverlay.nearestCorner(to: CGPoint(x: 1400, y: 40), in: screen), .bottomTrailing)
        XCTAssertEqual(CameraOverlay.nearestCorner(to: CGPoint(x: 40, y: 860), in: screen), .topLeading)
        XCTAssertEqual(CameraOverlay.nearestCorner(to: CGPoint(x: 1400, y: 860), in: screen), .topTrailing)
    }

    /// A screen that does not start at the origin — a second display sitting to the
    /// right of the built-in one — must not read as "always trailing".
    func testNearestCornerIsRelativeToTheDisplayNotTheOrigin() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(CameraOverlay.nearestCorner(to: CGPoint(x: 1500, y: 60), in: second), .bottomLeading)
    }
}
