import XCTest
@testable import FlowStateCore

/// The Look pane's two galleries, and what a click in either of them means.
///
/// This is here rather than left to the view because the bug it is about was invisible in
/// source: the moving-background tiles were wired to a value that only mattered once some
/// *other* control had been set, so clicking one did nothing at all and the whole section
/// read as broken. Both halves of that — which tiles are on screen, and what choosing one
/// changes — are plain data questions, so they are answered here where they can be proved.
final class LookBackdropTests: XCTestCase {

    // MARK: - Both sections, always

    /// The still gallery. Every backdrop that holds one picture, in a fixed order.
    func test_theStillSectionIsEveryBackdropThatDoesNotMove() {
        XCTAssertEqual(Backdrop.stillBackdrops,
                       [.midnight, .paper, .bali, .capeTown, .sanFrancisco, .alps, .tokyo, .sahara, .custom])
        XCTAssertEqual(Backdrop.stillBackdrops.map(\.label),
                       ["Midnight", "Paper", "Bali", "Cape Town", "San Francisco",
                        "Alps", "Tokyo", "Sahara", "Your photo"])
    }

    /// `.motion` is not a tile in the still grid. It used to be, and its only job was to
    /// reveal the moving section underneath — which is exactly the toggle that is gone.
    func test_motionIsNotATileInTheStillSection() {
        XCTAssertFalse(Backdrop.stillBackdrops.contains(.motion))
        XCTAssertTrue(Backdrop.allCases.contains(.motion), "still the stored value for a moving backdrop")
    }

    /// The moving gallery. Every style, including the six the section is named for.
    func test_theMovingSectionIsEveryStyle() {
        XCTAssertEqual(Backdrop.movingBackgrounds, MotionStyle.allCases)
        for style in [MotionStyle.fluid, .ocean, .clouds, .aurora, .silk, .nebula] {
            XCTAssertTrue(Backdrop.movingBackgrounds.contains(style), "\(style.rawValue) is missing")
        }
    }

    /// Neither list is a function of what is selected, which is what "both sections are
    /// always visible" amounts to once the view is out of the picture: the galleries are
    /// `static let`s, so there is no state you can be in where either has nothing to draw
    /// and no way for a selection to shrink one.
    func test_neitherSectionDependsOnWhatIsSelected() {
        let still = Backdrop.stillBackdrops
        let moving = Backdrop.movingBackgrounds
        XCTAssertFalse(still.isEmpty)
        XCTAssertFalse(moving.isEmpty)
        for backdrop in Backdrop.allCases {
            for style in MotionStyle.allCases {
                var look = LookSelection(backdrop: backdrop, motionStyle: style)
                look.choose(style)
                look.choose(Backdrop.paper)
                XCTAssertEqual(Backdrop.stillBackdrops, still)
                XCTAssertEqual(Backdrop.movingBackgrounds, moving)
            }
        }
    }

    // MARK: - Choosing a moving background

    /// The bug, stated as a test. From any still backdrop, clicking a moving tile has to
    /// land on that moving backdrop — not merely remember the style for later.
    func test_choosingAMovingBackgroundFromAStillOneSelectsIt() {
        for backdrop in Backdrop.stillBackdrops {
            for style in Backdrop.movingBackgrounds {
                var look = LookSelection(backdrop: backdrop, motionStyle: .fluid)
                look.choose(style)
                XCTAssertEqual(look.backdrop, .motion, "from \(backdrop.rawValue)")
                XCTAssertEqual(look.motionStyle, style, "from \(backdrop.rawValue)")
                XCTAssertTrue(look.isShowing(style))
            }
        }
    }

    /// Every one of them, from every one of them. A style that could not be reached from
    /// some particular starting point is the same failure wearing a different hat.
    func test_everyMovingBackgroundIsReachableFromEveryOther() {
        for from in Backdrop.movingBackgrounds {
            for to in Backdrop.movingBackgrounds {
                var look = LookSelection(backdrop: .motion, motionStyle: from)
                look.choose(to)
                XCTAssertTrue(look.isShowing(to), "\(from.rawValue) → \(to.rawValue)")
            }
        }
    }

    /// Clicking the tile that is already selected is not a way to turn it off.
    func test_choosingTheMovingBackgroundAlreadyShowingChangesNothing() {
        var look = LookSelection(backdrop: .motion, motionStyle: .aurora)
        look.choose(MotionStyle.aurora)
        XCTAssertEqual(look, LookSelection(backdrop: .motion, motionStyle: .aurora))
    }

    // MARK: - Choosing a still backdrop

    /// Motion vs Your photo, unchanged: a still backdrop is selected as itself, and the
    /// two are not the same thing.
    func test_choosingAStillBackdropSelectsIt() {
        var look = LookSelection(backdrop: .motion, motionStyle: .ocean)
        look.choose(Backdrop.custom)
        XCTAssertEqual(look.backdrop, .custom)
        XCTAssertTrue(look.isShowing(Backdrop.custom))
        XCTAssertFalse(look.isShowing(Backdrop.motion))
    }

    /// The moving style survives a trip through a still backdrop, so coming back to the
    /// section returns to the one you liked rather than to the default.
    func test_aStillBackdropDoesNotForgetTheMovingStyle() {
        var look = LookSelection(backdrop: .motion, motionStyle: .nebula)
        look.choose(Backdrop.tokyo)
        XCTAssertEqual(look.motionStyle, .nebula)
        XCTAssertFalse(look.isShowing(MotionStyle.nebula), "remembered is not the same as showing")
        look.choose(MotionStyle.nebula)
        XCTAssertTrue(look.isShowing(MotionStyle.nebula))
    }

    /// Exactly one tile is ringed across both galleries at any moment — the thing the two
    /// sections have to agree about now that they are on screen together.
    func test_exactlyOneTileIsSelectedAcrossBothSections() {
        for backdrop in Backdrop.allCases {
            let look = LookSelection(backdrop: backdrop, motionStyle: .silk)
            let still = Backdrop.stillBackdrops.filter { look.isShowing($0) }.count
            let moving = Backdrop.movingBackgrounds.filter { look.isShowing($0) }.count
            XCTAssertEqual(still + moving, 1, "\(backdrop.rawValue)")
        }
    }

    // MARK: - What each kind brings with it

    /// The controls under each gallery hang off the kind, so a backdrop landing in the
    /// wrong one silently loses its daylight picker or its rotation slider.
    func test_eachBackdropIsTheKindItsControlsAssume() {
        XCTAssertEqual(Backdrop.midnight.kind, .flat)
        XCTAssertEqual(Backdrop.paper.kind, .flat)
        XCTAssertEqual(Backdrop.capeTown.kind, .place)
        XCTAssertEqual(Backdrop.motion.kind, .motion)
        XCTAssertEqual(Backdrop.custom.kind, .photo)
        XCTAssertEqual(Backdrop.allCases.filter { $0.kind == .place }.count, 6)
    }

    /// Ambient mode sits above both sections now and is always offered, but it only has
    /// something to reveal behind a painted place or a moving background — the same rule
    /// `ContentView` applies when it decides whether to hide the chrome. Unchanged by this
    /// refactor, and asserted so the move to the top of the pane cannot quietly widen it.
    func test_ambientModeHasSomethingToRevealOnlyBehindAScene() {
        XCTAssertTrue(Backdrop.motion.isScene)
        XCTAssertTrue(Backdrop.bali.isScene)
        XCTAssertFalse(Backdrop.midnight.isScene)
        XCTAssertFalse(Backdrop.paper.isScene)
        XCTAssertFalse(Backdrop.custom.isScene)
    }

    /// Storage compatibility: the raw values are what is in everybody's settings file.
    func test_rawValuesAreUnchanged() {
        XCTAssertEqual(Backdrop.allCases.map(\.rawValue),
                       ["midnight", "paper", "bali", "capeTown", "sanFrancisco",
                        "alps", "tokyo", "sahara", "motion", "custom"])
    }
}
