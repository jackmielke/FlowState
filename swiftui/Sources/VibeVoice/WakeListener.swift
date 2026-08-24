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

    /// Throws away the current recognition task and starts a fresh one.
    ///
    /// A recognition task that has been fed nothing for the length of a conversation is
    /// not reliably still listening, and waiting for the fifty-second recycle to notice
    /// means up to fifty seconds where the wake phrase silently does nothing — right
    /// after hanging up, which is exactly when somebody tries it.
    /// Ignore both the phrase and the clap for a while. See `WakeListenerState.snooze`.
    func snooze(seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        state.snooze(until: until)
        claps.snooze(until: until)
        snoozedUntil = until
    }

    /// When the quiet ends, for the pill and the tooltip. Nil when not snoozed.
    private(set) var snoozedUntil: Date?

    var isSnoozed: Bool {
        guard let snoozedUntil else { return false }
        return Date() < snoozedUntil
    }

    func restart() {
        guard isRunning else { return start() }
        claps.reset()
        beginTask()
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
    var clapThreshold: Float { claps.threshold }
    /// The loudest thing heard in the last moment. Shown live, because a meter that
    /// visibly moves when you speak is the difference between "it is not detecting much"
    /// and knowing the microphone is reaching this code at all.
    var inputPeak: Float { claps.recentPeak }

    func beginClapCalibration() { claps.beginCalibration() }
    func endClapCalibration() -> ClapCalibration.Result? { claps.endCalibration() }
    var isCalibrating: Bool { claps.isCalibrating }
    var trace: [WakeTrace] { claps.trace }
    func clearTrace() { claps.clearTrace() }

    /// Everything the phrase and the claps did, whether or not it woke anything. Kept so
    /// a false trigger can be looked at afterwards rather than remembered.
    private(set) var phraseTrace: [WakeTrace] = []

    /// How many buffers have reached this, ever. The single most useful number when the
    /// wake phrase "does not work": zero means the audio never arrives and nothing in
    /// this file is at fault.
    private(set) nonisolated(unsafe) var buffersFed = 0

    /// Called from the audio tap with the same buffers the socket receives.
    nonisolated func feed(_ pcm16: Data) {
        buffersFed += 1
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
        // Sub-framed to 10 ms, and NOT one peak per callback.
        //
        // The tap hands over 2048 frames at the hardware rate — about 43 ms. Treating
        // that as one unit gave the detector 43 ms of resolution to judge things that
        // are measured in tens of milliseconds: a clap landing across two callbacks
        // measured 85 ms long and was thrown out for "too long to be a clap", which is
        // roughly half of all claps, rejected by arithmetic rather than by sound.
        if claps.feed(pcm16) {
            Task { @MainActor [weak self] in
                // Calibrating is measuring, not arming: a pair completed while teaching
                // it your clap must not also open a session.
                guard let self, self.clapEnabled, !self.claps.isCalibrating else { return }
                self.lastHeard = "(two claps)"
                self.onWake?()
            }
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
                    let changed = text != self.lastHeard
                    self.lastHeard = text
                    if self.state.heard(text, phrase: self.phrase, now: Date()) {
                        self.notePhrase(.woke, detail: "heard \"\(text.suffix(40))\"")
                        self.onWake?()
                    } else if changed, !text.isEmpty {
                        // Everything it heard, whether or not it matched. Without this the
                        // panel can say only that nothing happened, which is the one thing
                        // already obvious from the outside.
                        self.notePhrase(.rejected, detail: "\"\(text.suffix(40))\"")
                    }
                    if result.isFinal { self.state.utteranceEnded() }
                }
                if error != nil { self.state.utteranceEnded() }
            }
        }
        state.utteranceEnded()
    }

    private func notePhrase(_ kind: WakeTrace.Kind, detail: String) {
        // One line per utterance rather than per refinement: partial results arrive
        // several times a second and each is a longer version of the last.
        if let last = phraseTrace.first, last.kind == kind,
           Date().timeIntervalSince(last.at) < 1.2 {
            phraseTrace[0] = WakeTrace(at: Date(), kind: kind, peak: 0, detail: detail)
            return
        }
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
    private var recent: [WakeTrace] = []

    /// Set while calibrating: every sub-frame peak is kept, whatever the thresholds say.
    /// The thresholds are the unknown being measured, so they cannot be the filter.
    private var recording: [ClapCalibration.Sample]?

    func beginCalibration() {
        lock.lock(); recording = []; lock.unlock()
    }

    /// - Returns: nil if calibration was never started.
    func endCalibration() -> ClapCalibration.Result? {
        lock.lock()
        let taken = recording
        recording = nil
        lock.unlock()
        guard let taken, !taken.isEmpty else { return nil }
        return ClapCalibration.analyse(taken)
    }

    var isCalibrating: Bool {
        lock.lock(); defer { lock.unlock() }; return recording != nil
    }

    /// Time derived from how much audio has been seen, not from the wall clock.
    ///
    /// The gap between two claps is a quarter of a second, and every rule here is
    /// measured in tens of milliseconds. `Date()` at the moment a buffer happens to be
    /// processed carries whatever scheduling jitter the machine had, which is the same
    /// order as the thing being measured. Counting samples cannot drift and cannot jitter.
    private var samplesSeen = 0

    /// Decays rather than resetting, so a meter driven by it falls smoothly instead of
    /// flickering between a peak and zero.
    private var peakHold: Float = 0
    private var snoozedUntil: Date?

    /// 10 ms at 24 kHz. Fine enough to see a clap's attack and its decay as separate
    /// things, coarse enough that a peak is a handful of comparisons.
    private static let subFrame = 240

    /// True when a pair completed inside this buffer.
    func snooze(until: Date) {
        lock.lock(); snoozedUntil = until; lock.unlock()
    }

    func feed(_ pcm16: Data) -> Bool {
        let total = pcm16.count / 2
        guard total > 0 else { return false }

        var woke = false
        pcm16.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            var i = 0
            lock.lock()
            while i < total {
                let end = Swift.min(i + Self.subFrame, total)
                var m: Int32 = 0
                for k in i..<end { m = Swift.max(m, Int32(p[k].magnitude)) }
                let peak = Float(m) / 32_767
                peakHold = Swift.max(peak, peakHold * 0.88)
                let at = Double(samplesSeen + i) / 24_000
                if recording != nil { recording?.append(.init(at: at, peak: peak)) }

                switch detector.feed(peak: peak, at: at) {
                case .nothing:
                    // Loud enough to notice but under the bar. Recorded because "I
                    // clapped and nothing appeared" is the report that cannot be acted
                    // on — this is what turns it into a number.
                    if peak > detector.roomLevel * 4, peak > 0.05 {
                        note(WakeTrace(at: Date(), kind: .rejected, peak: peak,
                                       detail: "too quiet — needs \(Self.db(detector.threshold))"))
                    }
                case .armed(let pk):
                    note(WakeTrace(at: Date(), kind: .armed, peak: pk,
                                   detail: "clap heard — waiting for a second"))
                case .rejected(let why, let pk):
                    note(WakeTrace(at: Date(), kind: .rejected, peak: pk, detail: why))
                case .wake(let pk):
                    // Detected, recorded, and deliberately not acted on while snoozed:
                    // the panel should still show that it heard the pair, or the panic
                    // key looks like the detector breaking.
                    if let until = snoozedUntil, Date() < until {
                        note(WakeTrace(at: Date(), kind: .rejected, peak: pk,
                                       detail: "two claps — but you asked for quiet"))
                    } else {
                        note(WakeTrace(at: Date(), kind: .woke, peak: pk, detail: "two claps"))
                        woke = true
                    }
                }
                i = end
            }
            samplesSeen += total
            lock.unlock()
        }
        return woke
    }

    private static func db(_ v: Float) -> String {
        v <= 0.0005 ? "—" : String(format: "%.0f dB", 20 * log10(v))
    }

    var sensitivity: Float {
        get { lock.lock(); defer { lock.unlock() }; return detector.sensitivity }
        set { lock.lock(); detector.sensitivity = newValue; lock.unlock() }
    }

    var roomLevel: Float {
        lock.lock(); defer { lock.unlock() }; return detector.roomLevel
    }

    var recentPeak: Float {
        lock.lock(); defer { lock.unlock() }; return peakHold
    }

    /// What a clap has to beat right now, for the tuning display.
    var threshold: Float {
        lock.lock(); defer { lock.unlock() }; return detector.threshold
    }

    var trace: [WakeTrace] {
        lock.lock(); defer { lock.unlock() }; return recent
    }

    func clearTrace() {
        lock.lock(); recent.removeAll(); lock.unlock()
    }

    /// Caller holds the lock.
    private func note(_ t: WakeTrace) {
        // Near-misses arrive in bursts; one line per burst is enough to read.
        if let last = recent.first, last.detail == t.detail,
           Date().timeIntervalSince(last.at) < 0.25 { return }
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
