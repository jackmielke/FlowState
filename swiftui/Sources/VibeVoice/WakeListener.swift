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
    /// Built per call rather than held: `feed` runs on the audio thread, and a stored
    /// property on a main-actor type cannot be read from there. Constructing an
    /// `AVAudioFormat` is a handful of field copies, against a buffer allocation and a
    /// memcpy in the same function.
    private nonisolated static func format() -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16,
                      sampleRate: AudioEngine.targetRate,
                      channels: 1,
                      interleaved: true)
    }

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

    /// Two claps, detected from the samples directly — no recogniser involved. See
    /// `ClapDetector`. Kept here rather than in its own type because it is fed from the
    /// same tap and answers the same question.
    private let claps = ClapBox()

    /// Whether the clap wake is armed. Cheap either way; the detector is a few floats.
    var clapEnabled = false

    /// 0...1. Higher triggers more easily. See `ClapDetector.sensitivity`.
    var clapSensitivity: Float {
        get { claps.sensitivity }
        set { claps.sensitivity = newValue }
    }

    /// Live numbers for the tuning panel.
    var roomLevel: Float { claps.roomLevel }
    var trace: [WakeTrace] { claps.trace }
    func clearTrace() { claps.clearTrace() }

    /// Everything the phrase and the claps did, whether or not it woke anything. Kept so
    /// a false trigger can be looked at afterwards rather than remembered.
    private(set) var phraseTrace: [WakeTrace] = []

    /// Called from the audio tap with the same buffers the socket receives.
    nonisolated func feed(_ pcm16: Data) {
        guard let format = Self.format() else { return }
        let frames = pcm16.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm16.withUnsafeBytes { raw in
            guard let src = raw.baseAddress, let dst = buffer.int16ChannelData?[0] else { return }
            memcpy(dst, src, frames * 2)
        }
        if let peak = Self.peak(pcm16), claps.feed(peak: peak, at: Date()) {
            Task { @MainActor [weak self] in
                guard let self, self.clapEnabled else { return }
                self.lastHeard = "(two claps)"
                self.onWake?()
            }
        }

        Task { @MainActor [weak self] in self?.request?.append(buffer) }
    }

    /// Highest absolute sample in the frame, 0...1.
    private nonisolated static func peak(_ pcm16: Data) -> Float? {
        let n = pcm16.count / 2
        guard n > 0 else { return nil }
        return pcm16.withUnsafeBytes { raw -> Float in
            let p = raw.bindMemory(to: Int16.self)
            var m: Int32 = 0
            for i in 0..<n { m = max(m, Int32(p[i].magnitude)) }
            return Float(m) / 32_767
        }
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
                        self.notePhrase(.woke, detail: text)
                        self.onWake?()
                    }
                    if result.isFinal { self.state.utteranceEnded() }
                }
                if error != nil { self.state.utteranceEnded() }
            }
        }
        state.utteranceEnded()
    }

    private func notePhrase(_ kind: WakeTrace.Kind, detail: String) {
        phraseTrace.insert(WakeTrace(at: Date(), kind: kind, peak: 0, detail: detail), at: 0)
        if phraseTrace.count > 20 { phraseTrace.removeLast() }
    }

    func clearPhraseTrace() { phraseTrace.removeAll() }

    private func endTask() {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }
}


/// The clap detector, reachable from the audio thread.
///
/// `ClapDetector` is a value type holding a running estimate of the room, so it has to
/// live somewhere mutable — and that somewhere is written to every 20 ms from the capture
/// tap. A lock rather than the main actor, for the same reason `UtteranceRecorder` uses
/// one: hopping queues for a few floats a frame would cost more than the work.
final class ClapBox: @unchecked Sendable {
    private let lock = NSLock()
    private var detector = ClapDetector()
    private let started = Date()

    /// The last few decisions, newest first, for the tuning panel. Bounded — this is a
    /// diagnostic, not a log, and it is written to from the audio thread.
    private var recent: [WakeTrace] = []

    var sensitivity: Float {
        get { lock.lock(); defer { lock.unlock() }; return detector.sensitivity }
        set { lock.lock(); detector.sensitivity = newValue; lock.unlock() }
    }

    var roomLevel: Float {
        lock.lock(); defer { lock.unlock() }; return detector.roomLevel
    }

    var trace: [WakeTrace] {
        lock.lock(); defer { lock.unlock() }; return recent
    }

    func clearTrace() {
        lock.lock(); recent.removeAll(); lock.unlock()
    }

    /// - Returns: true when the pair completed.
    func feed(peak: Float, at now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let event = detector.feed(peak: peak, at: now.timeIntervalSince(started))
        switch event {
        case .nothing:
            return false
        case .armed(let p):
            note(WakeTrace(at: now, kind: .armed, peak: p, detail: "first of a pair — waiting for the second"))
            return false
        case .rejected(let why, let p):
            note(WakeTrace(at: now, kind: .rejected, peak: p, detail: why))
            return false
        case .wake(let p):
            note(WakeTrace(at: now, kind: .woke, peak: p, detail: "two claps"))
            return true
        }
    }

    private func note(_ t: WakeTrace) {
        recent.insert(t, at: 0)
        if recent.count > 40 { recent.removeLast() }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        detector.reset()
    }
}

/// One line in the tuning panel.
struct WakeTrace: Identifiable, Sendable {
    enum Kind: Sendable { case armed, rejected, woke }
    let id = UUID()
    let at: Date
    let kind: Kind
    let peak: Float
    let detail: String
}
