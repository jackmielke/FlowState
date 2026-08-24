import XCTest
@testable import VibeVoiceCore

/// The vocabulary, the once-per-utterance rule and the gate. Everything the recorder can
/// be told to do without anybody touching it.
final class VoiceCommandTests: XCTestCase {

    // MARK: - Matching

    func testEveryCommandMatchesItsOwnPhrases() {
        for command in VoiceCommand.allCases {
            for phrase in command.phrases {
                XCTAssertEqual(VoiceCommandVocabulary.match(phrase), command,
                               "\"\(phrase)\" should be \(command.rawValue)")
            }
        }
    }

    func testToolNamesAreUniqueAndSnakeCase() {
        let names = VoiceCommand.allCases.map(\.toolName)
        XCTAssertEqual(Set(names).count, names.count)
        for name in names {
            XCTAssertEqual(name, name.lowercased())
            XCTAssertFalse(name.contains(" "))
        }
    }

    func testHeardInsideASentence() {
        XCTAssertEqual(VoiceCommandVocabulary.match("okay, let's stop recording now"),
                       .stopRecording)
        XCTAssertEqual(VoiceCommandVocabulary.match("Hey, show my face please."),
                       .showFace)
    }

    func testPunctuationAndCaseDoNotMatter() {
        XCTAssertEqual(VoiceCommandVocabulary.match("START RECORDING!"), .startRecording)
        XCTAssertEqual(VoiceCommandVocabulary.match("Pause recording."), .pauseRecording)
        // The recogniser punctuates as it likes — "Hey, Flow." is the reason
        // `WakePhrase.normalise` exists — so punctuation cannot be allowed to matter.
        XCTAssertEqual(VoiceCommandVocabulary.match("Pause — recording?"), .pauseRecording)
    }

    func testNothingInOrdinarySpeech() {
        for line in ["I started the meeting at four",
                     "the face of it is strange",
                     "let's pause for a second",
                     "recording studios are expensive",
                     "can you stop that"] {
            XCTAssertNil(VoiceCommandVocabulary.match(line), line)
        }
    }

    func testNegationIsNotACommand() {
        XCTAssertNil(VoiceCommandVocabulary.match("don't stop recording"))
        XCTAssertNil(VoiceCommandVocabulary.match("do not start recording yet"))
        XCTAssertNil(VoiceCommandVocabulary.match("I didn't hide my face"))
        XCTAssertNil(VoiceCommandVocabulary.match("we can't pause recording on this one"))
    }

    func testTheLastCommandSaidWins() {
        XCTAssertEqual(VoiceCommandVocabulary.match("pause recording — no, stop recording"),
                       .stopRecording)
    }

    func testOnlyTheTailCounts() {
        let said = "start recording" + String(repeating: " and then we talked", count: 8)
        XCTAssertNil(VoiceCommandVocabulary.match(said),
                     "a phrase that has scrolled out of the tail is not being said now")
    }

    func testAWordEndingInAPhraseIsNotAPhrase() {
        XCTAssertNil(VoiceCommandVocabulary.match("restart recording"),
                     "the match has to start a word")
    }

    // MARK: - Firing once per utterance

    func testFiresOnceWhileTheTranscriptRepeatsItself() {
        var listener = VoiceCommandListener()
        let now = Date()
        XCTAssertEqual(listener.heard("stop recording", now: now), .stopRecording)
        XCTAssertNil(listener.heard("stop recording", now: now.addingTimeInterval(0.2)))
        XCTAssertNil(listener.heard("stop recording now", now: now.addingTimeInterval(0.4)))
    }

    func testADifferentCommandIsNotSwallowedByTheCooldown() {
        var listener = VoiceCommandListener()
        let now = Date()
        XCTAssertEqual(listener.heard("pause recording", now: now), .pauseRecording)
        XCTAssertEqual(listener.heard("pause recording. resume recording",
                                      now: now.addingTimeInterval(1)),
                       .resumeRecording,
                       "pausing and then resuming a second later is a real thing to do")
    }

    func testTheSameCommandFiresAgainAfterTheCooldownAndSomeTalking() {
        var listener = VoiceCommandListener()
        let now = Date()
        XCTAssertEqual(listener.heard("start recording", now: now), .startRecording)
        let later = "start recording" + String(repeating: " right okay so", count: 6) + " start recording"
        XCTAssertEqual(listener.heard(later, now: now.addingTimeInterval(30)), .startRecording)
    }

    func testSnoozeSilencesEverything() {
        var listener = VoiceCommandListener()
        let now = Date()
        listener.snooze(until: now.addingTimeInterval(60))
        XCTAssertNil(listener.heard("stop recording", now: now.addingTimeInterval(1)))
        XCTAssertEqual(listener.heard("stop recording", now: now.addingTimeInterval(61)),
                       .stopRecording)
    }

    // MARK: - The gate

    private func context(recording: Bool = false,
                         paused: Bool = false,
                         face: Bool = false,
                         enabled: Bool = true,
                         recordingEnabled: Bool = true,
                         recordingBlocked: String? = nil,
                         cameraBlocked: String? = nil) -> VoiceCommandContext {
        VoiceCommandContext(commandsEnabled: enabled,
                            recordingEnabled: recordingEnabled,
                            recordingBlocked: recordingBlocked,
                            isRecording: recording,
                            isPaused: paused,
                            cameraBlocked: cameraBlocked,
                            isFaceVisible: face)
    }

    func testTheMasterSwitchStopsEveryCommand() {
        for command in VoiceCommand.allCases {
            let decision = VoiceCommandGate.decide(command, in: context(enabled: false))
            XCTAssertFalse(decision.isPerform, command.rawValue)
            if case .blocked = decision {} else { XCTFail("\(command.rawValue) should be blocked") }
        }
    }

    func testNothingTransportHappensWithoutAMicrophone() {
        for command in VoiceCommand.allCases where command.isTransport {
            let decision = VoiceCommandGate.decide(command, in: context(recordingEnabled: false))
            XCTAssertFalse(decision.isPerform, command.rawValue)
        }
        // The camera commands are unrelated to the microphone and must still work.
        XCTAssertTrue(VoiceCommandGate.decide(.showFace, in: context(recordingEnabled: false)).isPerform)
    }

    func testADeniedPermissionBlocksTheStartAndSaysWhy() {
        let why = "Screen Recording is off for FlowState."
        let decision = VoiceCommandGate.decide(.startRecording,
                                               in: context(recordingBlocked: why))
        XCTAssertEqual(decision, .blocked(why))
    }

    func testStoppingIsNeverBlockedByAPermission() {
        let decision = VoiceCommandGate.decide(.stopRecording,
                                               in: context(recording: true,
                                                           recordingBlocked: "Screen Recording is off."))
        XCTAssertTrue(decision.isPerform, "a take that is already running has to be stoppable")
    }

    func testTransportStateMachine() {
        // Idle
        XCTAssertTrue(VoiceCommandGate.decide(.startRecording, in: context()).isPerform)
        XCTAssertFalse(VoiceCommandGate.decide(.stopRecording, in: context()).isPerform)
        XCTAssertFalse(VoiceCommandGate.decide(.pauseRecording, in: context()).isPerform)
        XCTAssertFalse(VoiceCommandGate.decide(.resumeRecording, in: context()).isPerform)

        // Running
        let running = context(recording: true)
        XCTAssertFalse(VoiceCommandGate.decide(.startRecording, in: running).isPerform)
        XCTAssertTrue(VoiceCommandGate.decide(.stopRecording, in: running).isPerform)
        XCTAssertTrue(VoiceCommandGate.decide(.pauseRecording, in: running).isPerform)
        XCTAssertFalse(VoiceCommandGate.decide(.resumeRecording, in: running).isPerform)

        // Paused
        let paused = context(recording: true, paused: true)
        XCTAssertTrue(VoiceCommandGate.decide(.stopRecording, in: paused).isPerform)
        XCTAssertFalse(VoiceCommandGate.decide(.pauseRecording, in: paused).isPerform)
        XCTAssertTrue(VoiceCommandGate.decide(.resumeRecording, in: paused).isPerform)
    }

    func testStartingWhilePausedContinuesTheTakeItDoesNotStartASecondOne() {
        let paused = context(recording: true, paused: true)
        XCTAssertEqual(VoiceCommand.startRecording.resolved(in: paused), .resumeRecording)
        XCTAssertTrue(VoiceCommandGate.decide(.startRecording, in: paused).isPerform)
        // And nowhere else: with a take actually running, start is still a repeat.
        XCTAssertEqual(VoiceCommand.startRecording.resolved(in: context(recording: true)),
                       .startRecording)
    }

    func testFaceCommandsAreIdempotent() {
        XCTAssertTrue(VoiceCommandGate.decide(.showFace, in: context(face: false)).isPerform)
        XCTAssertFalse(VoiceCommandGate.decide(.showFace, in: context(face: true)).isPerform)
        XCTAssertTrue(VoiceCommandGate.decide(.hideFace, in: context(face: true)).isPerform)
        XCTAssertFalse(VoiceCommandGate.decide(.hideFace, in: context(face: false)).isPerform)
    }

    func testADeniedCameraBlocksShowingButNeverHiding() {
        let why = "Camera is off for FlowState."
        XCTAssertEqual(VoiceCommandGate.decide(.showFace, in: context(cameraBlocked: why)),
                       .blocked(why))
        XCTAssertTrue(VoiceCommandGate.decide(.hideFace,
                                              in: context(face: true, cameraBlocked: why)).isPerform,
                      "a revoked permission must not trap a face on screen")
    }

    func testEveryRefusalSaysSomething() {
        let cases: [(VoiceCommand, VoiceCommandContext)] = [
            (.stopRecording, context()),
            (.pauseRecording, context()),
            (.resumeRecording, context(recording: true)),
            (.startRecording, context(recording: true)),
            (.showFace, context(face: true)),
            (.hideFace, context()),
            (.startRecording, context(enabled: false)),
        ]
        for (command, ctx) in cases {
            let spoken = VoiceCommandGate.decide(command, in: ctx).spoken
            XCTAssertNotNil(spoken, command.rawValue)
            XCTAssertFalse(spoken!.isEmpty, command.rawValue)
        }
    }
}
