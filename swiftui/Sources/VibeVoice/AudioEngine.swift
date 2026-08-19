import Foundation
import AVFoundation
import Combine

/// Thread-safe scratch shared between the realtime audio threads and the UI.
final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _mic: Float = 0
    private var _out: Float = 0
    var mic: Float { get { lock.lock(); defer { lock.unlock() }; return _mic }
                    set { lock.lock(); _mic = newValue; lock.unlock() } }
    var out: Float { get { lock.lock(); defer { lock.unlock() }; return _out }
                     set { lock.lock(); _out = newValue; lock.unlock() } }
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

    /// Called on the audio thread with a chunk of mono PCM16 @ 24 kHz.
    var onMicPCM: ((Data) -> Void)?

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

    static func requestMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !running else { return }

        let input = engine.inputNode
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

        let desc = String(format: "in %.0f Hz × %d ch → wire 24000 Hz mono PCM16 · out %.0f Hz",
                          hwFormat.sampleRate, hwFormat.channelCount,
                          engine.mainMixerNode.outputFormat(forBus: 0).sampleRate)
        FileHandle.standardError.write(Data(("[audio] " + desc + "\n").utf8))

        DispatchQueue.main.async {
            self.formatDescription = desc
            self.running = true
            self.lastError = nil
        }
        startUITimer()
    }

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
        levels.mic = Self.rms(buffer)
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
        onMicPCM?(Data(bytes: ch[0], count: bytes))
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
