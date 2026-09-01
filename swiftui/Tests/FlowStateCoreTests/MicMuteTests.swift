import XCTest
@testable import FlowStateCore

/// Muting the microphone.
///
/// The interesting failures here are all silent ones. A mute that still reaches the
/// socket is a privacy bug nobody can see from the UI; a mute that withholds frames from
/// the recorder instead of silencing them corrupts the file's timeline in a way that only
/// shows up when someone plays it back later. So the rules are pinned here rather than
/// left to three call sites to agree on.
final class MicMuteTests: XCTestCase {

    // MARK: - The promise

    /// The whole point. Muted audio never reaches the model, connected or not.
    func test_mutedAudioNeverReachesTheModel() {
        XCTAssertFalse(MicMute.route(muted: true, connected: true).toModel)
        XCTAssertFalse(MicMute.route(muted: true, connected: false).toModel)
    }

    func test_unmutedAudioReachesTheModelOnlyWhileConnected() {
        XCTAssertTrue(MicMute.route(muted: false, connected: true).toModel)
        XCTAssertFalse(MicMute.route(muted: false, connected: false).toModel)
    }

    // MARK: - The recorder's clock

    /// The microphone is the recording's timeline — see `SessionRecorder.appendMic`. If
    /// mute ever starts dropping chunks instead of silencing them, a muted minute stops
    /// occupying a minute of the file and every reply after it slides earlier.
    func test_recorderIsFedInEveryState() {
        for muted in [true, false] {
            for connected in [true, false] {
                XCTAssertTrue(MicMute.route(muted: muted, connected: connected).toRecorder,
                              "muted=\(muted) connected=\(connected)")
            }
        }
    }

    func test_onlyMutedAudioIsSilenced() {
        XCTAssertTrue(MicMute.route(muted: true, connected: true).silenced)
        XCTAssertFalse(MicMute.route(muted: false, connected: true).silenced)
    }

    /// Same length, no samples. The length is the load-bearing half.
    func test_silenceIsTheSameLengthAndAllZeroes() {
        let chunk = Data([0x01, 0xFF, 0x7F, 0x80, 0x00, 0x22])
        let quiet = MicMute.silence(like: chunk)
        XCTAssertEqual(quiet.count, chunk.count)
        XCTAssertTrue(quiet.allSatisfy { $0 == 0 })
    }

    func test_silenceOfNothingIsNothing() {
        XCTAssertEqual(MicMute.silence(like: Data()).count, 0)
    }

    /// A muted stretch and an unmuted stretch of the same capture must occupy the same
    /// number of samples, or the recording drifts.
    func test_aMutedStretchOccupiesTheSameTimelineAsAnUnmutedOne() {
        let captured = (0..<50).map { _ in Data(repeating: 0x33, count: 960) }

        func timeline(mutedFrom: Int) -> Int {
            captured.enumerated().reduce(0) { total, pair in
                let muted = pair.offset >= mutedFrom
                let route = MicMute.route(muted: muted, connected: true)
                guard route.toRecorder else { return total }
                let written = route.silenced ? MicMute.silence(like: pair.element) : pair.element
                return total + written.count
            }
        }

        XCTAssertEqual(timeline(mutedFrom: 20), timeline(mutedFrom: captured.count))
    }

    // MARK: - Measurement

    /// Silence is not an utterance. Measuring it would report a five-minute mute as a
    /// five-minute thing the user said.
    func test_mutedAudioIsNotMeasuredAsSpeech() {
        XCTAssertFalse(MicMute.route(muted: true, connected: true).toMeasurement)
        // Still measured with the socket down — the measurement is of the user, not of
        // the network.
        XCTAssertTrue(MicMute.route(muted: false, connected: false).toMeasurement)
    }

    // MARK: - What the control says

    func test_theTwoStatesNeverLookOrReadAlike() {
        XCTAssertNotEqual(MicMute.symbol(muted: true), MicMute.symbol(muted: false))
        XCTAssertNotEqual(MicMute.label(muted: true), MicMute.label(muted: false))
        XCTAssertTrue(MicMute.symbol(muted: true).contains("slash"))
        XCTAssertFalse(MicMute.symbol(muted: false).contains("slash"))
    }

    /// The tooltip says what the click does, so it must name the *opposite* of the
    /// current state. A tooltip that reads "Mute" while already muted is the single most
    /// effective way to make a toggle feel broken.
    func test_helpNamesTheActionNotTheState() {
        for live in [true, false] {
            let whenMuted = MicMute.help(muted: true, live: live).lowercased()
            XCTAssertTrue(whenMuted.hasPrefix("unmute"), whenMuted)

            let whenOpen = MicMute.help(muted: false, live: live).lowercased()
            XCTAssertTrue(whenOpen.hasPrefix("mute"), whenOpen)
            XCTAssertFalse(whenOpen.hasPrefix("unmute"), whenOpen)
        }
    }

    /// Muted-while-idle is the state a persisted mute lands you in on launch, and it is
    /// the one that most needs explaining — the microphone will still be off after a
    /// restart, and nothing else on screen says so.
    func test_helpExplainsThatAMuteOutlivesTheSession() {
        XCTAssertTrue(MicMute.help(muted: true, live: false).lowercased().contains("restart"))
    }

    func test_bothNotesAreSentencesAndSayWhichWayItWent() {
        for muted in [true, false] {
            let note = MicMute.note(muted: muted)
            XCTAssertTrue(note.hasSuffix("."), note)
            XCTAssertTrue(note.lowercased().contains("microphone"), note)
        }
        XCTAssertNotEqual(MicMute.note(muted: true), MicMute.note(muted: false))
    }
}
