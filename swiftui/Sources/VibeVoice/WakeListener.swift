import Foundation
import Speech
import AVFoundation
import VibeVoiceCore

/// Always listening for one phrase, and nothing else.
///
/// On-device recognition, always — `requiresOnDeviceRecognition` is set and the listener
/// refuses to run without it. A wake word is a microphone that is open all day; the only
/// version of that worth shipping is one where the audio never leaves the machine. It is
/// also the only version that works on a plane, and the only one that costs nothing per
/// hour.
///
/// It feeds on the same PCM the socket would get, so waking does not mean switching audio
/// paths mid-sentence — the engine is already running, already echo-cancelled, and the
/// tap is already installed.
@MainActor
final class WakeListener {

    /// Called when the phrase is heard. Opening a session is the caller's business.
    var onWake: (() -> Void)?
    /// Diagnostics for Settings — the last thing it thought it heard.
    private(set) var lastHeard: String = ""
    private(set) var isRunning = false
    private(set) var problem: String?

    var phrase: WakePhrase = .heyFlow

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var state = WakeListenerState()
    private var restartTimer: Timer?

    /// The format the engine hands over: 24 kHz mono PCM16, matching `AudioEngine`.
    /// `nonisolated` because `feed` runs on the audio thread — see there.
    nonisolated(unsafe) private static let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: AudioEngine.targetRate,
                                              channels: 1,
                                              interleaved: true)

    static func authorize() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { k in
            SFSpeechRecognizer.requestAuthorization { k.resume(returning: $0) }
        }
    }

    func start() {
        guard !isRunning else { return }
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition is not available for this language."
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            // Never silently fall back to the network for this. See the type comment.
            problem = "This Mac cannot recognise speech on-device, so the wake phrase is off."
            return
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            problem = "Speech recognition is off for FlowState — turn it on in System Settings › Privacy & Security › Speech Recognition."
            return
        }
        problem = nil
        isRunning = true
        beginTask()

        // Recognition tasks do not run forever; they stop on their own after a minute or
        // so of audio and simply produce nothing after that. A wake word that quietly
        // stops working after a minute is worse than one that was never on, so it is
        // recycled on a timer rather than waiting to notice.
        let t = Timer(timeInterval: 50, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginTask() }
        }
        RunLoop.main.add(t, forMode: .common)
        restartTimer = t
    }

    func stop() {
        restartTimer?.invalidate(); restartTimer = nil
        endTask()
        isRunning = false
    }

    /// Called from the audio tap with the same buffers the socket receives.
    nonisolated func feed(_ pcm16: Data) {
        guard let format = Self.format else { return }
        let frames = pcm16.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm16.withUnsafeBytes { raw in
            guard let src = raw.baseAddress, let dst = buffer.int16ChannelData?[0] else { return }
            memcpy(dst, src, frames * 2)
        }
        Task { @MainActor [weak self] in self?.request?.append(buffer) }
    }

    private func beginTask() {
        endTask()
        guard let recognizer else { return }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        r.requiresOnDeviceRecognition = true
        // Nothing said to a wake word is worth keeping, and Apple will otherwise use
        // some of it to improve the recogniser.
        if #available(macOS 15.0, *) { r.addsPunctuation = false }
        request = r
        task = recognizer.recognitionTask(with: r) { [weak self] result, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.lastHeard = text
                    if self.state.heard(text, phrase: self.phrase, now: Date()) {
                        self.onWake?()
                    }
                    if result.isFinal { self.state.utteranceEnded() }
                }
                if error != nil { self.state.utteranceEnded() }
            }
        }
        state.utteranceEnded()
    }

    private func endTask() {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }
}
