import XCTest
@testable import VibeVoiceCore

/// The geometry behind the floating Settings pane.
///
/// Every one of these is a bug that was visible before it was a test: a pane that crawled
/// at half the pointer's speed, a pane that jumped on release after being dragged into an
/// edge, a pane that stood at 620 points to show four rows, and — in a window smaller than
/// the pane — a clamp whose lower bound exceeded its upper one, which is a crash rather
/// than a layout mistake.
final class PanelLayoutTests: XCTestCase {

    private let window = CGSize(width: 1200, height: 800)
    private let ideal = CGSize(width: 440, height: 620)

    // MARK: - Size

    func test_unmeasuredContentGetsTheIdealSize() {
        let s = PanelLayout.size(ideal: ideal, contentHeight: nil, in: window)
        XCTAssertEqual(s, ideal)
    }

    /// The whole point of measuring: a short tab is a short pane, not a tall pane with
    /// 400 points of nothing under it.
    func test_shortContentContractsThePane() {
        let s = PanelLayout.size(ideal: ideal, contentHeight: 300, in: window)
        XCTAssertEqual(s.height, 300)
        XCTAssertEqual(s.width, 440, "width is never content-driven")
    }

    func test_longContentIsCappedAtTheIdealHeight() {
        let s = PanelLayout.size(ideal: ideal, contentHeight: 4000, in: window)
        XCTAssertEqual(s.height, 620)
    }

    func test_contentShorterThanTheMinimumStillGetsTheMinimum() {
        let s = PanelLayout.size(ideal: ideal, contentHeight: 40, in: window)
        XCTAssertEqual(s.height, PanelLayout.minHeight)
    }

    /// The window always wins over both.
    func test_aShortWindowShrinksThePane() {
        let s = PanelLayout.size(ideal: ideal, contentHeight: 600,
                                 in: CGSize(width: 1000, height: 420))
        XCTAssertEqual(s.height, 420 - PanelLayout.margin * 2)
    }

    func test_aWindowSmallerThanTheMinimumDoesNotProduceASliver() {
        let s = PanelLayout.size(ideal: ideal, contentHeight: 600,
                                 in: CGSize(width: 200, height: 100))
        XCTAssertEqual(s.width, PanelLayout.minWidth)
        XCTAssertEqual(s.height, PanelLayout.minHeight)
    }

    // MARK: - Clamping

    func test_clampKeepsThePaneInsideTheMargins() {
        let s = CGSize(width: 440, height: 620)
        let p = PanelLayout.clamp(CGPoint(x: -400, y: -400), size: s, in: window)
        XCTAssertEqual(p, CGPoint(x: PanelLayout.margin, y: PanelLayout.margin))

        let q = PanelLayout.clamp(CGPoint(x: 9_000, y: 9_000), size: s, in: window)
        XCTAssertEqual(q.x, window.width - s.width - PanelLayout.margin)
        XCTAssertEqual(q.y, window.height - s.height - PanelLayout.margin)
    }

    /// In a window too small for the pane the upper bound is below the lower one. An
    /// unordered `min`/`max` pair there is a trap, not a misplaced pane.
    func test_clampSurvivesAWindowSmallerThanThePane() {
        let p = PanelLayout.clamp(CGPoint(x: 500, y: 500),
                                  size: CGSize(width: 440, height: 620),
                                  in: CGSize(width: 300, height: 300))
        XCTAssertEqual(p, CGPoint(x: PanelLayout.margin, y: PanelLayout.margin))
    }

    func test_defaultOriginIsCentredAndBelowTheHeader() {
        let s = CGSize(width: 440, height: 400)
        let p = PanelLayout.defaultOrigin(s, in: window)
        XCTAssertEqual(p.x, (window.width - s.width) / 2)
        XCTAssertEqual(p.y, 64)
    }

    // MARK: - Dragging

    /// Absolute from the anchor, so the pane lands under the pointer rather than at some
    /// accumulated fraction of the way there.
    func test_dragIsOneToOneWithTheTranslation() {
        let s = CGSize(width: 440, height: 400)
        let p = PanelLayout.dragged(from: CGPoint(x: 100, y: 100),
                                    by: CGSize(width: 60, height: -30),
                                    size: s, in: window)
        XCTAssertEqual(p, CGPoint(x: 160, y: 70))
    }

    /// Dragged hard into the left edge and brought back: the pane must return with the
    /// pointer, not stay offset by however far it was clamped.
    func test_draggingIntoAnEdgeAndBackDoesNotDriftFromThePointer() {
        let s = CGSize(width: 440, height: 400)
        let anchor = CGPoint(x: 100, y: 100)
        let pinned = PanelLayout.dragged(from: anchor, by: CGSize(width: -600, height: 0),
                                         size: s, in: window)
        XCTAssertEqual(pinned.x, PanelLayout.margin, "held against the edge")

        let back = PanelLayout.dragged(from: anchor, by: CGSize(width: 25, height: 0),
                                       size: s, in: window)
        XCTAssertEqual(back.x, 125, accuracy: 0.001)
    }

    // MARK: - Settling a measured height

    func test_firstMeasurementIsAlwaysAccepted() {
        XCTAssertEqual(PanelLayout.settledHeight(432.4, current: nil), 432)
    }

    /// Sub-pixel noise from a font metric must not animate the pane.
    func test_tinyChangesAreIgnored() {
        XCTAssertNil(PanelLayout.settledHeight(432.2, current: 432))
    }

    func test_realChangesAreTaken() {
        XCTAssertEqual(PanelLayout.settledHeight(519.6, current: 432), 520)
    }

    /// A measurement mid-transition can arrive as zero or NaN; reacting to either would
    /// collapse the pane for a frame.
    func test_nonsenseMeasurementsAreRejected() {
        XCTAssertNil(PanelLayout.settledHeight(0, current: 432))
        XCTAssertNil(PanelLayout.settledHeight(-10, current: 432))
        XCTAssertNil(PanelLayout.settledHeight(.nan, current: 432))
        XCTAssertNil(PanelLayout.settledHeight(.infinity, current: 432))
    }
}
