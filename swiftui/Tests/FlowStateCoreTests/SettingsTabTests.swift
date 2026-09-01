import XCTest
@testable import FlowStateCore

/// The Settings tabs.
///
/// Small surface, but two of these fail silently in ways nobody notices until a user
/// does: a tab whose stored name no longer exists reopens Settings on an empty pane, and
/// a label longer than a word breaks the strip onto two lines at 440 points wide.
final class SettingsTabTests: XCTestCase {

    func test_storedSelectionRoundTrips() {
        for tab in SettingsTab.allCases {
            XCTAssertEqual(SettingsTab(stored: tab.rawValue), tab)
        }
    }

    /// A renamed or dropped tab must land on General, not on nothing.
    func test_unknownOrMissingSelectionFallsBackToGeneral() {
        XCTAssertEqual(SettingsTab(stored: nil), .general)
        XCTAssertEqual(SettingsTab(stored: ""), .general)
        XCTAssertEqual(SettingsTab(stored: "sounds"), .general)
    }

    func test_generalIsFirst() {
        XCTAssertEqual(SettingsTab.allCases.first, .general)
    }

    /// Seven one-word labels is what the strip is sized for.
    func test_labelsAreShortEnoughForTheStrip() {
        XCTAssertEqual(SettingsTab.allCases.count, 7)
        for tab in SettingsTab.allCases {
            XCTAssertFalse(tab.label.contains(" "), "\(tab.rawValue) label wraps")
            XCTAssertLessThanOrEqual(tab.label.count, 8, "\(tab.rawValue) label")
        }
    }

    /// The label alone leaves "Access" and "Data" as guesses — every tab owes the tooltip
    /// and VoiceOver a sentence saying what is inside it.
    func test_everyTabExplainsItself() {
        for tab in SettingsTab.allCases {
            XCTAssertFalse(tab.symbol.isEmpty, "\(tab.rawValue) symbol")
            XCTAssertGreaterThan(tab.blurb.count, 20, "\(tab.rawValue) blurb")
            XCTAssertTrue(tab.blurb.hasSuffix("."), "\(tab.rawValue) blurb is a sentence")
        }
    }
}
