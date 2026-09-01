import XCTest
@testable import FlowStateCore

/// Two shortcuts on one chord, and what the user gets told about it.
///
/// The failure this file exists to prevent is silence. Carbon hands a chord to one owner
/// and refuses everybody after, with no visible symptom: the Settings pane goes on
/// showing both rows set, both look bound, and one of them is dead. That was the state
/// before — picking ⌃⇧F for two rows registered one and lost the other without a word.
final class HotkeyConflictTests: XCTestCase {

    private func binding(_ role: String, _ id: String, _ label: String) -> HotkeyBinding {
        HotkeyBinding(role: role, comboID: id, label: label)
    }

    // MARK: - Two of our own rows on one chord

    func test_twoRolesOnOneChordClash() {
        let clashes = HotkeyConflict.clashes(among: [
            binding("Wake it up", "ctrlQ", "⌃Q"),
            binding("Stop everything", "ctrlQ", "⌃Q"),
        ])
        XCTAssertEqual(clashes.count, 1)
        XCTAssertEqual(clashes[0].comboID, "ctrlQ")
        XCTAssertEqual(clashes[0].roles, ["Wake it up", "Stop everything"])
        XCTAssertTrue(clashes[0].message.contains("⌃Q"))
        // Both rows are named, because either one is the one to move.
        XCTAssertTrue(clashes[0].message.contains("Wake it up"))
        XCTAssertTrue(clashes[0].message.contains("Stop everything"))
    }

    func test_distinctChordsDoNotClash() {
        XCTAssertTrue(HotkeyConflict.clashes(among: [
            binding("Wake it up", "ctrlQ", "⌃Q"),
            binding("Stop everything", "escape", "Esc"),
            binding("Talk to it", "ctrlShiftF", "⌃⇧F"),
        ]).isEmpty)
    }

    /// The regression that matters most in practice: "Off" is the app's default answer
    /// for three of the five rows, and an empty id is not a chord anybody is fighting
    /// over. Treating it as one would warn about a conflict between two shortcuts that
    /// do not exist.
    func test_switchedOffRowsNeverClash() {
        XCTAssertTrue(HotkeyConflict.clashes(among: [
            binding("Wake it up", "", "Off"),
            binding("Stop everything", "", "Off"),
            binding("Talk to it", "", "Off"),
        ]).isEmpty)
    }

    func test_threeRolesOnOneChordAreOneClashNotThree() {
        let clashes = HotkeyConflict.clashes(among: [
            binding("A", "ctrlQ", "⌃Q"),
            binding("B", "ctrlQ", "⌃Q"),
            binding("C", "ctrlQ", "⌃Q"),
        ])
        XCTAssertEqual(clashes.count, 1)
        XCTAssertEqual(clashes[0].roles, ["A", "B", "C"])
    }

    func test_clashLookupFindsEitherSide() {
        let bindings = [
            binding("Wake it up", "ctrlQ", "⌃Q"),
            binding("Stop everything", "ctrlQ", "⌃Q"),
            binding("Talk to it", "ctrlShiftF", "⌃⇧F"),
        ]
        // Both rows warn. Only telling the second one would leave the user reading a
        // pane where the row they are looking at is fine and the problem is elsewhere.
        XCTAssertNotNil(HotkeyConflict.clash(for: "Wake it up", among: bindings))
        XCTAssertNotNil(HotkeyConflict.clash(for: "Stop everything", among: bindings))
        XCTAssertNil(HotkeyConflict.clash(for: "Talk to it", among: bindings))
    }

    /// The order the rows are given in is the order they are named in, so the sentence
    /// under a picker does not reshuffle itself between redraws.
    func test_clashOrderFollowsInputOrder() {
        let clashes = HotkeyConflict.clashes(among: [
            binding("Talk to it", "ctrlShiftF", "⌃⇧F"),
            binding("Wake it up", "ctrlQ", "⌃Q"),
            binding("Start or stop recording", "ctrlShiftF", "⌃⇧F"),
            binding("Stop everything", "ctrlQ", "⌃Q"),
        ])
        XCTAssertEqual(clashes.map(\.comboID), ["ctrlShiftF", "ctrlQ"])
        XCTAssertEqual(clashes[0].roles, ["Talk to it", "Start or stop recording"])
    }

    // MARK: - Somebody else owns it

    func test_refusedMessageNamesTheRowAndTheChord() {
        let m = HotkeyConflict.refused(role: "Wake it up", label: "⌃Q")
        XCTAssertTrue(m.contains("⌃Q"))
        XCTAssertTrue(m.contains("Wake it up"))
        // No OSStatus. -9878 is not something a person can act on.
        XCTAssertFalse(m.contains("9878"))
    }

    // MARK: - Chords that already mean something

    func test_advisoriesExistForTheChordsThatCostSomething() {
        XCTAssertNotNil(HotkeyConflict.advisory(for: "ctrlQ"))
        XCTAssertNotNil(HotkeyConflict.advisory(for: "escape"))
        XCTAssertNotNil(HotkeyConflict.advisory(for: "optionSpace"))
    }

    /// A note under every option is noise, and noise is how the one that matters gets
    /// skipped. ⌘⇧R takes nothing from anybody.
    func test_ordinaryChordsGetNoNote() {
        XCTAssertNil(HotkeyConflict.advisory(for: "cmdShiftR"))
        XCTAssertNil(HotkeyConflict.advisory(for: "ctrlShiftEscape"))
        XCTAssertNil(HotkeyConflict.advisory(for: ""))
    }

    func test_escapeAdvisorySaysWhenItIsListening() {
        let note = HotkeyConflict.advisory(for: "escape") ?? ""
        // The whole reason bare Escape is safe to offer is that it is not always bound,
        // so the note has to say so — a user who thinks it is always live will file the
        // times it does nothing as a bug.
        XCTAssertTrue(note.contains("live"))
        XCTAssertTrue(note.contains("in front"))
    }
}

/// When bare Escape is allowed to be a global shortcut.
///
/// Two booleans, and the reason they get their own file's worth of attention is that
/// both wrong answers are silent. Bind too eagerly and Escape stops cancelling dialogs
/// everywhere on the Mac, with nothing on screen connecting that to this app. Bind too
/// shyly and the deactivate key does nothing at the one moment it is reached for.
final class SessionScopedHotkeyTests: XCTestCase {

    func test_boundOnlyWhenLiveAndInTheBackground() {
        XCTAssertTrue(SessionScopedHotkey.shouldBind(sessionLive: true, appIsFrontmost: false))
    }

    /// The 99% of the day with nothing running. Escape is nobody's but the user's.
    func test_notBoundWhileIdle() {
        XCTAssertFalse(SessionScopedHotkey.shouldBind(sessionLive: false, appIsFrontmost: false))
        XCTAssertFalse(SessionScopedHotkey.shouldBind(sessionLive: false, appIsFrontmost: true))
    }

    /// Inside our own window Escape already means "cancel this edit" and "close this
    /// panel", and a Carbon hotkey beats an in-window shortcut — including our own.
    func test_notBoundWhileWeAreTheAppInFront() {
        XCTAssertFalse(SessionScopedHotkey.shouldBind(sessionLive: true, appIsFrontmost: true))
    }
}
