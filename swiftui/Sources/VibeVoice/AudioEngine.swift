import Foundation
import AVFoundation
import Combine
import VibeVoiceCore

/// Thread-safe scratch shared between the realtime audio threads and the UI.
///
/// `muted` lives here rather than beside the `@Published` mirror because the capture tap
/// has to read it on every buffer, forty times a second, on a real-time thread. Reading
/// a main-actor property from there is exactly the hazard this box exists to avoid.
final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _mic: Float = 0
    private var _out: Float = 0
    private var _muted = false
    var mic: Float { get { lock.lock(); defer { lock.unlock() }; return _mic }
                    set { lock.lock(); _mic = newValue; lock.unlock() } }
    var out: Float { get { lock.lock(); defer { lock.unlock() }; return _out }
                     set { lock.lock(); _out = newValue; lock.unlock() } }
    var muted: Bool { get { lock.lock(); defer { lock.unlock() }; return _muted }
                      set { lock.lock(); _muted = newValue; lock.unlock() } }
}

/// Mic capture -> mono PCM16 @ 24 kHz, and PCM16 @ 24 kHz -> speakers.
/// The hardware runs at 44.1/48 kHz float; every sample crossing that boundary
/// goes through an AVAudioConverter. Actual rates are logged at start().
final class AudioEngine: ObservableObject, @unchecked Sendable {

    static let targetRate: Double = 24_000

    @Published private(set) var micLevel: Float = 0
    /// Last ~1.6 s of real mic RMS, newest last. Drives the waveform meter.
    @Published private(set) var micHistory: [Float] = Array(repeating: 0, count: 48)
    @Published private(set) var outLevel: Float = 0
    @Published private(set) var running = false
    @Published private(set) var lastError: String?
    @Published private(set) var formatDescription: String = "—"
    /// True when the OS voice-processing unit (acoustic echo cancellation) is active.
    /// When false the model hears itself through the speakers — use headphones.
    @Published private(set) var echoCancellation = false

    /// The microphone gate. Main-thread mirror of `levels.muted`, which is the copy the
    /// capture thread actually reads — see `setMuted`.
    ///
    /// Deliberately survives `stop()`: mute is the user's standing instruction about
    /// their microphone, not a property of the current session, so ending a session and
    /// starting another one must not quietly reopen it.
    @Published private(set) var isMuted = false

    /// Called on the audio thread with a chunk of mono PCM16 @ 24 kHz, and whether the
    /// microphone was muted when it was captured.
    ///
    /// While muted the chunk is digital silence of exactly the length the real audio
    /// would have been, so a consumer using it as a clock keeps a true timeline. The flag
    /// is passed rather than looked up because `isMuted` is main-actor state and this
    /// fires on the capture thread; see `MicMute.route` for what each consumer does
    /// with it.
    var onMicPCM: ((Data, Bool) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let levels = LevelBox()
    private var converter: AVAudioConverter?
    private var uiTimer: Timer?
    private var pendingScheduled = 0
    private let pendingLock = NSLock()

    /// Format we speak to the network in.
    private lazy var wireFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Self.targetRate,
        channels: 1,
        interleaved: true)!

    /// Format the player node renders (engine resamples to the device rate for us).
    private lazy var playbackFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Self.targetRate,
        channels: 1,
        interleaved: false)!

    // MARK: - Permissions

    /// Whether this Mac will let the app record at all, asked without prompting.
    ///
    /// `requestMicAccess` cannot answer this question: it shows a dialog the first time,
    /// and a voice command must never make a permission sheet appear out of nowhere for
    /// something the user said to somebody else in the room.
    static var micPermitted: Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: return false
        // `.notDetermined` counts as permitted: the ask happens when the engine starts,
        // which is a moment the user has just asked for.
        default: return true
        }
    }

    static func requestMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: - Mute

    /// Opens or closes the microphone gate.
    ///
    /// Safe at any time, running or not — the flag is read per buffer, so a mute taken
    /// mid-sentence takes effect on the next one (about 20 ms) rather than at the next
    /// engine restart. Nothing here touches the engine graph: tearing the tap down and
    /// building it back up on every mute would drop the recorder's clock and re-trigger
    /// the voice-processing unit's format negotiation, which is the expensive part of
    /// `start()`.
    func setMuted(_ on: Bool) {
        levels.muted = on
        // Otherwise the last level captured before the gate closed stays on the meter,
        // and a muted orb sits there frozen mid-glow.
        if on { levels.mic = 0 }
        let publish = { [weak self] in
            guard let self else { return }
            self.isMuted = on
            if on {
                self.micLevel = 0
                self.micHistory = Array(repeating: 0, count: 48)
            }
        }
        if Thread.isMainThread { publish() } else { DispatchQueue.main.async(execute: publish) }
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !running else { return }

        let input = engine.inputNode

        // Instantiate the main mixer BEFORE touching voice processing. Lazily creating
        // it afterwards makes the engine reconfigure into a state where start() fails
        // with -10875 (kAudioUnitErr_FormatNotSupported), and no connect format avoids
        // it — measured across a full format x destination matrix. This one line is
        // the difference between the engine starting and not.
        _ = engine.mainMixerNode

        // Acoustic echo cancellation. Without this the model's own voice comes back
        // in through the mic, server VAD reads it as the user interrupting, and the
        // app talks to itself in a loop ("Hi again. Hi again.").
        //
        // Order matters: this must be enabled BEFORE the engine starts, before the
        // converter is built, and before the tap is installed — switching the input
        // to the voice-processing unit CHANGES its format, so the format has to be
        // read afterwards or the converter is built against a stale rate.
        var aec = false
        do {
            try input.setVoiceProcessingEnabled(true)
            try engine.outputNode.setVoiceProcessingEnabled(true)
            aec = true
        } catch {
            FileHandle.standardError.write(Data(
                ("[audio] voice processing unavailable (\(error.localizedDescription)) — "
                 + "echo cancellation OFF, use headphones\n").utf8))
        }

        // Read the format AFTER enabling voice processing, not before.
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw NSError(domain: "VibeVoice", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No input device available (hardware format reported 0 Hz)."])
        }

        guard let conv = AVAudioConverter(from: hwFormat, to: wireFormat) else {
            throw NSError(domain: "VibeVoice", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not build a converter from \(hwFormat) to 24 kHz PCM16."])
        }
        conv.sampleRateConverterQuality = .max
        // The voice-processing unit reports a 9-channel input on this hardware (the
        // mic array), with its processed mono signal duplicated across every channel.
        // AVAudioConverter cannot derive a downmix matrix for that layout and silently
        // produces SILENCE, so pick channel 0 explicitly. Measured: without this the
        // converted stream is digital zero while the tap itself is at -55 dBFS.
        if hwFormat.channelCount > 1 {
            conv.channelMap = [0]
        }
        converter = conv

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        // Tap the mic in the HARDWARE format; convert per-buffer.
        input.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { [weak self] buf, _ in
            self?.handleMic(buf)
        }
        // Tap the player so the orb reacts to what is really being rendered.
        player.installTap(onBus: 0, bufferSize: 2048, format: playbackFormat) { [weak self] buf, _ in
            self?.levels.out = Self.rms(buf)
        }

        engine.prepare()
        try engine.start()
        player.play()

        let desc = String(format: "in %.0f Hz × %d ch → wire 24000 Hz mono PCM16 · out %.0f Hz · AEC %@",
                          hwFormat.sampleRate, hwFormat.channelCount,
                          engine.mainMixerNode.outputFormat(forBus: 0).sampleRate,
                          aec ? "on" : "OFF (use headphones)")
        FileHandle.standardError.write(Data(("[audio] " + desc + "\n").utf8))

        DispatchQueue.main.async {
            self.formatDescription = desc
            self.echoCancellation = aec
            self.running = true
            self.lastError = nil
        }
        startUITimer()
    }

    /// Whether the capture tap is actually installed and running.
    ///
    /// `running` is the published mirror of this, set on the next turn of the main queue
    /// so SwiftUI sees it as a change rather than a write during view evaluation. That
    /// makes it useless to anything asking immediately after `start()` — which is what
    /// a recording that opens its own microphone does.
    var isCapturing: Bool { engine.isRunning }

    func stop() {
        guard running else { return }
        uiTimer?.invalidate(); uiTimer = nil
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        player.removeTap(onBus: 0)
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.detach(player)
        converter = nil
        levels.mic = 0; levels.out = 0
        DispatchQueue.main.async {
            self.running = false; self.micLevel = 0; self.outLevel = 0
            self.micHistory = Array(repeating: 0, count: 48)
        }
    }

    private func startUITimer() {
        DispatchQueue.main.async {
            self.uiTimer?.invalidate()
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                // light smoothing so the orb glides instead of jittering
                self.micLevel += (self.levels.mic - self.micLevel) * 0.45
                self.outLevel += (self.levels.out - self.outLevel) * 0.45
                self.micHistory.removeFirst()
                self.micHistory.append(max(self.levels.mic, self.levels.out * 0.9))
            }
            RunLoop.main.add(t, forMode: .common)
            self.uiTimer = t
        }
    }

    // MARK: - Capture path

    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        let muted = levels.muted
        // Dead, not quiet. See `MicMute`.
        levels.mic = muted ? 0 : Self.rms(buffer)
        guard let conv = converter else { return }

        let ratio = Self.targetRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, inStatus in
            if supplied { inStatus.pointee = .noDataNow; return nil }
            supplied = true
            inStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let ch = out.int16ChannelData else {
            if let err { FileHandle.standardError.write(Data("[audio] convert: \(err)\n".utf8)) }
            return
        }
        let bytes = Int(out.frameLength) * MemoryLayout<Int16>.size
        let chunk = Data(bytes: ch[0], count: bytes)
        // The conversion above runs even while muted, on purpose. It is the resampler
        // that decides how many 24 kHz frames a hardware buffer becomes, so running it
        // either way is what makes a muted second and an unmuted second the same length
        // on the recorder's timeline. Reconstructing that length by arithmetic instead
        // rounds every buffer and drifts the file by seconds over a long mute.
        onMicPCM?(muted ? MicMute.silence(like: chunk) : chunk, muted)
    }

    // MARK: - Playback path

    /// Schedule raw PCM16 mono @ 24 kHz coming off the socket.
    func enqueue(pcm16: Data) {
        guard running, pcm16.count >= 2 else { return }
        let frames = AVAudioFrameCount(pcm16.count / 2)
        guard let buf = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: frames) else { return }
        buf.frameLength = frames
        guard let dst = buf.floatChannelData?[0] else { return }
        pcm16.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(frames) { dst[i] = Float(Int16(littleEndian: src[i])) / 32768.0 }
        }
        pendingLock.lock(); pendingScheduled += 1; pendingLock.unlock()
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.pendingLock.lock(); self.pendingScheduled -= 1
            let empty = self.pendingScheduled <= 0
            self.pendingLock.unlock()
            if empty { self.levels.out = 0 }
        }
        if !player.isPlaying { player.play() }
    }

    /// Barge-in: drop everything queued for playback immediately.
    func flushPlayback() {
        guard running else { return }
        player.stop()
        pendingLock.lock(); pendingScheduled = 0; pendingLock.unlock()
        levels.out = 0
        player.play()
    }

    var isPlayingAudio: Bool {
        pendingLock.lock(); defer { pendingLock.unlock() }; return pendingScheduled > 0
    }

    // MARK: - Util

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        if let f = buffer.floatChannelData {
            let chans = Int(buffer.format.channelCount)
            for c in 0..<chans {
                let p = f[c]
                for i in 0..<n { sum += p[i] * p[i] }
            }
            sum /= Float(n * max(chans, 1))
        } else if let s = buffer.int16ChannelData {
            let p = s[0]
            for i in 0..<n { let v = Float(p[i]) / 32768.0; sum += v * v }
            sum /= Float(n)
        }
        return sqrt(sum)
    }
}
