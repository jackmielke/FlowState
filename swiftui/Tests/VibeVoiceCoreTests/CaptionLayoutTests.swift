import XCTest
import CoreGraphics
@testable import VibeVoiceCore

/// The caption strip's one layout promise: **the width does not depend on the caption**.
///
/// Worth testing rather than eyeballing, because the failure it replaces was only ever
/// visible in motion — the strip walking outwards word by word and snapping back on every
/// wrap. A screenshot of the old behaviour looks fine.
final class CaptionLayoutTests: XCTestCase {

    /// A 16" laptop, a 5K display, and a small scaled one.
    private let laptop: CGFloat = 1728
    private let big: CGFloat = 2560
    private let small: CGFloat = 500

    func testTheWidthIsTheSameOnAGivenScreenWhateverIsBeingSaid() {
        // There is no caption in the signature at all — the strongest form of the
        // guarantee, and the reason this is the shape of the API.
        XCTAssertEqual(CaptionLayout.width(visibleWidth: laptop),
                       CaptionLayout.width(visibleWidth: laptop))
        XCTAssertEqual(CaptionLayout.width(visibleWidth: laptop), CaptionLayout.preferredWidth)
        XCTAssertEqual(CaptionLayout.width(visibleWidth: big), CaptionLayout.preferredWidth)
    }

    func testItNarrowsToFitASmallScreenButKeepsTheEdgeMargins() {
        let w = CaptionLayout.width(visibleWidth: small)
        XCTAssertEqual(w, small - CaptionLayout.screenMargin * 2)
        XCTAssertLessThan(w, CaptionLayout.preferredWidth)
    }

    func testItNeverGoesBelowTheFloorOnATinyScreen() {
        XCTAssertEqual(CaptionLayout.width(visibleWidth: 120), CaptionLayout.minimumWidth)
    }

    /// A display change can hand us a zero before the new screen is enumerated.
    func testAnUnusableScreenWidthFallsBackToThePreferredWidth() {
        XCTAssertEqual(CaptionLayout.width(visibleWidth: 0), CaptionLayout.preferredWidth)
        XCTAssertEqual(CaptionLayout.width(visibleWidth: .nan), CaptionLayout.preferredWidth)
    }

    func testTheCardLeavesRoomForItsShadowOnBothSides() {
        XCTAssertEqual(CaptionLayout.cardWidth(panelWidth: 520),
                       520 - CaptionLayout.shadowMargin * 2)
        // Degenerate panel: still a positive width, because a zero-width frame is a
        // SwiftUI layout warning and an invisible caption.
        XCTAssertGreaterThan(CaptionLayout.cardWidth(panelWidth: 0), 0)
    }

    // ------------------------------------------------------------------ height --

    func testHeightComesFromTheContent() {
        XCTAssertEqual(CaptionLayout.height(measured: 88, fallback: 52), 88)
        XCTAssertEqual(CaptionLayout.height(measured: 130.2, fallback: 88), 131,
                       "rounded up, so the bottom line is not clipped by a fraction")
    }

    func testAMeasurementOfNothingKeepsTheHeightItHad() {
        XCTAssertEqual(CaptionLayout.height(measured: 0, fallback: 88), 88)
        XCTAssertEqual(CaptionLayout.height(measured: .nan, fallback: 88), 88)
        XCTAssertEqual(CaptionLayout.height(measured: -4, fallback: 88), 88)
    }

    /// The first frame of a brand-new caption, before anything has been measured.
    func testTheStartingHeightIsAWholeLineRatherThanNothing() {
        XCTAssertGreaterThan(CaptionLayout.singleLineHeight, CaptionLayout.shadowMargin * 2)
        XCTAssertEqual(CaptionLayout.height(measured: 0, fallback: CaptionLayout.singleLineHeight),
                       CaptionLayout.singleLineHeight)
    }

    func testALongCaptionStopsAtTheTopOfTheScreenInsteadOfRunningOffIt() {
        let h = CaptionLayout.height(measured: 4000, fallback: 52, visibleHeight: 900)
        XCTAssertLessThanOrEqual(h, 900 - CaptionLayout.bottomGap)
    }

    // ------------------------------------------------------------------ origin --

    /// The property that actually keeps the words still: same width in, same left edge
    /// out, so nothing on screen moves sideways when the text changes.
    func testTheLeftEdgeDoesNotMoveWhenOnlyTheHeightChanges() {
        let midX: CGFloat = 1728 / 2
        let w = CaptionLayout.width(visibleWidth: laptop)
        XCTAssertEqual(CaptionLayout.originX(panelWidth: w, visibleMidX: midX),
                       CaptionLayout.originX(panelWidth: w, visibleMidX: midX))
        XCTAssertEqual(CaptionLayout.originX(panelWidth: w, visibleMidX: midX), midX - w / 2)
    }

    func testTheOriginIsWholePointsSoTheEdgeStaysCrisp() {
        let x = CaptionLayout.originX(panelWidth: 521, visibleMidX: 864.5)
        XCTAssertEqual(x, x.rounded())
    }
}
