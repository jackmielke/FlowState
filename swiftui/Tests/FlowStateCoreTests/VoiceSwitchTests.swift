import XCTest
@testable import FlowStateCore

/// Changing the voice.
///
/// The failure this replaces was a quiet one: the setting was stored, the app said "you'll
/// hear it on the next reply", and the session kept the old voice until it was closed by
/// hand. So the rule that matters here is the one about a LIVE session — a change made
/// while connected has to come back as `.reconnect`, or the app is lying again.
final class VoiceSwitchTests: XCTestCase {

    private let voices = ["alloy", "ash", "coral", "marin", "cedar"]

    // MARK: - The rule

    /// Live session, different voice: the socket has to be recycled.
    func test_changingVoiceWhileLiveReconnects() {
        XCTAssertEqual(VoiceSwitch.plan(from: "marin", to: "cedar", live: true, known: voices),
                       .reconnect)
    }

    /// Nothing connected: just store it. Opening a session purely to apply a setting
    /// would start billing for a conversation nobody asked to have.
    func test_changingVoiceWhileIdleOnlyStores() {
        XCTAssertEqual(VoiceSwitch.plan(from: "marin", to: "cedar", live: false, known: voices),
                       .stored)
    }

    /// Re-picking the voice already in use must not drop the conversation. This is the
    /// one that a chip picker hits constantly — SwiftUI writes the binding back on any
    /// re-render — so treating it as a change would reconnect at random.
    func test_pickingTheSameVoiceDoesNothing() {
        XCTAssertEqual(VoiceSwitch.plan(from: "marin", to: "marin", live: true, known: voices),
                       .unchanged)
        XCTAssertEqual(VoiceSwitch.plan(from: "marin", to: "Marin ", live: true, known: voices),
                       .unchanged)
    }

    // MARK: - Names

    /// Speech gives us "Cedar", the API wants "cedar", and the settings file must hold
    /// the spelling the API accepts — a stored name it rejects fails the NEXT connect,
    /// somewhere that looks nothing like a voice change.
    func test_spokenNamesResolveToTheAPISpelling() {
        XCTAssertEqual(VoiceSwitch.resolve("  Cedar ", known: voices), "cedar")
        XCTAssertEqual(VoiceSwitch.plan(from: "marin", to: "CEDAR", live: true, known: voices),
                       .reconnect)
    }

    /// A voice we do not ship changes nothing and reconnects nothing.
    func test_unknownVoiceIsRefusedRatherThanStored() {
        XCTAssertEqual(VoiceSwitch.plan(from: "marin", to: "gravel", live: true, known: voices),
                       .unknown("gravel"))
        XCTAssertNil(VoiceSwitch.resolve("gravel", known: voices))
        XCTAssertFalse(VoiceSwitch.needsReconnect(.unknown("gravel")))
    }

    func test_emptyRequestIsUnknownNotAChange() {
        XCTAssertEqual(VoiceSwitch.plan(from: "marin", to: "   ", live: true, known: voices),
                       .unknown(""))
    }

    // MARK: - What is said about it

    /// Only the reconnect case may promise a reconnect, and it says so before the socket
    /// goes down — the user did not ask for a disconnect and is about to watch one.
    func test_onlyTheReconnectPlanMentionsReconnecting() {
        XCTAssertEqual(VoiceSwitch.note(.reconnect, voice: "cedar", known: voices)?
                        .contains("reconnect"), true)
        XCTAssertEqual(VoiceSwitch.note(.stored, voice: "cedar", known: voices)?
                        .contains("reconnect"), false)
    }

    /// Asking for the voice you already have leaves no mark on the transcript.
    func test_unchangedFilesNoTranscriptLine() {
        XCTAssertNil(VoiceSwitch.note(.unchanged, voice: "marin", known: voices))
        XCTAssertTrue(VoiceSwitch.spoken(.unchanged, voice: "marin").contains("marin"))
    }

    /// The refusal names the voices there actually are, when the caller passes them.
    func test_unknownVoiceMessageListsWhatThereIs() {
        let line = VoiceSwitch.note(.unknown("gravel"), voice: "marin", known: voices)
        XCTAssertEqual(line?.contains("gravel"), true)
        XCTAssertEqual(line?.contains("cedar"), true)
        XCTAssertEqual(VoiceSwitch.note(.unknown("gravel"), voice: "marin")?.contains("cedar"),
                       false)
    }

    func test_needsReconnectMatchesThePlan() {
        XCTAssertTrue(VoiceSwitch.needsReconnect(.reconnect))
        XCTAssertFalse(VoiceSwitch.needsReconnect(.stored))
        XCTAssertFalse(VoiceSwitch.needsReconnect(.unchanged))
    }
}
