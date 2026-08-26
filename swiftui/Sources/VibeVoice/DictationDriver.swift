import AppKit
import Foundation
import VibeVoiceCore

/// The thing that owns the clock, the mic and the round trip.
///
/// `HotkeyGesture.Recognizer` decides what a press means and `Dictation.Session` decides
/// what is allowed to happen next; both are pure and tested. This class is what is left
/// over once those are extracted — the real timer, the recorder, the network call and the
/// insertion — and it is deliberately thin, because none of it can be tested without a Mac
/// and a microphone.
@MainActor
final class DictationDriver: ObservableObject {

    /// What the widget should be showing. The three states look different on purpose: a
    /// user who cannot tell dictation from a live session will talk into the wrong one.
    enum Indicator: Equatable {
        case off
        case listening
        case working
    }

    @Published private(set) var indicator: Indicator = .off
    @Published private(set) var lastError: String?

    private var recognizer = HotkeyGesture.Recognizer()
    private var session = Dictation.Session()
    private let recorder = DictationRecorder()
    private var deadlineTimer: Timer?

    /// Supplied by AppState so the recognizer knows whether a tap means "hang up".
    var isVoiceModeActive: () -> Bool = { false }
    /// Called when the gesture asks for the full session to start or stop.
    var onStartVoiceMode: () -> Void = {}
    var onStopVoiceMode: () -> Void = {}
    /// Where transcripts get logged, so dictation shows up in the same history as speech.
    var onTranscript: (String) -> Void = { _ in }
    /// Whether the user wants the small sounds. Same switch as every other earcon.
    var earconsEnabled: () -> Bool = { true }

    // MARK: - Hotkey edges

    func keyDown() {
        recognizer.isVoiceModeActive = isVoiceModeActive()
        handle(recognizer.keyDown(at: now))
        armTimer()
    }

    func keyUp() {
        recognizer.isVoiceModeActive = isVoiceModeActive()
        handle(recognizer.keyUp(at: now))
        armTimer()
    }

    /// The app lost focus, the hotkey was rebound, the screen locked. Anything in flight is
    /// abandoned rather than left holding the microphone open.
    func reset() {
        handle(recognizer.reset())
        armTimer()
    }

    // MARK: -

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// One timer, re-armed from `nextDeadline`, rather than a poll.
    ///
    /// The recognizer is explicit about when it next needs to be looked at, and honouring
    /// that means the common case — nothing pressed — costs nothing at all.
    private func armTimer() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard let deadline = recognizer.nextDeadline else { return }
        let delay = max(0, deadline - now)
        deadlineTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.handle(self.recognizer.tick(at: self.now))
                self.armTimer()
            }
        }
    }

    private func handle(_ action: HotkeyGesture.Action?) {
        guard let action else { return }
        switch action {
        case .startVoiceMode:  onStartVoiceMode()
        case .stopVoiceMode:   onStopVoiceMode()
        case .beginDictation:  beginDictation()
        case .endDictation:    endDictation()
        case .cancelDictation: cancelDictation()
        }
    }

    // MARK: - The utterance

    private func beginDictation() {
        guard session.beginListening() else { return }
        lastError = nil
        do {
            try recorder.start()
            indicator = .listening
            // After the recorder starts, not before: a chime that plays and *then* fails
            // to open the mic teaches you to trust a sound that is sometimes a lie.
            EarconPlayer.shared.play(.dictateOpen, id: "dictateOpen", enabled: earconsEnabled())
        } catch {
            session.cancel()
            indicator = .off
            report("Could not open the microphone: \(error.localizedDescription)")
        }
    }

    private func endDictation() {
        guard session.finishListening() else { return }
        indicator = .working
        EarconPlayer.shared.play(.dictateClose, id: "dictateClose", enabled: earconsEnabled())

        guard let file = recorder.stop() else {
            // Too short to contain speech. Silent no-op rather than an error — a stray
            // brush of the key is not something worth telling anybody about.
            session.transcribed("")
            session.finished()
            indicator = .off
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await WhisperTranscriber.transcribe(file)
                await MainActor.run { self.insert(text) }
            } catch {
                await MainActor.run {
                    self.session.cancel()
                    self.indicator = .off
                    self.report(error.localizedDescription)
                }
            }
        }
    }

    private func cancelDictation() {
        recorder.discard()
        session.cancel()
        indicator = .off
    }

    private func insert(_ text: String) {
        defer {
            session.finished()
            indicator = .off
        }
        guard session.transcribed(text), !text.isEmpty else { return }
        onTranscript(text)
        do {
            let method = try TextInserter.insert(text)
            FileHandle.standardError.write(Data(
                "[dictation] inserted \(text.count) chars via \(method.rawValue)\n".utf8))
        } catch {
            // The words are not lost: they are on the clipboard either way, and the
            // transcript already has them. Say so rather than just failing.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            report("\(error.localizedDescription) Copied to the clipboard instead.")
        }
    }

    private func report(_ message: String) {
        lastError = message
        FileHandle.standardError.write(Data("[dictation] \(message)\n".utf8))
    }
}
