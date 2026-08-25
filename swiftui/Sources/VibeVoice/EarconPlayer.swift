import Foundation
import AVFoundation
import VibeVoiceCore

/// Plays the small sounds. See `Earcon` for what they are and why they exist.
///
/// Its own engine, not the conversation's. The capture engine has voice processing on it,
/// which exists to remove the assistant's voice from the microphone — running these
/// through it would put them through echo cancellation, which is both pointless and a
/// good way to disturb a tuning that took three days to get right. This is a player node
/// and a mixer, started on first use and left running: starting an engine takes long
/// enough to be heard as a delay before a sound whose whole job is to be immediate.
@MainActor
final class EarconPlayer {

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var started = false

    /// 24 kHz mono to match everything else here. These are pure tones under 1 kHz; a
    /// higher rate would buy nothing.
    private static let rate: Double = 24_000
    private static let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)

    /// Rendered once each. Four short buffers is a few kilobytes, and synthesising on the
    /// main thread at the moment of playing would be a stutter in the one place it shows.
    private var cache: [String: AVAudioPCMBuffer] = [:]

    func play(_ earcon: Earcon, id: String) {
        guard let format = Self.format else { return }
        guard let buffer = cache[id] ?? make(earcon, format: format) else { return }
        cache[id] = buffer

        if !started {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            do { try engine.start() } catch { return }
            started = true
        }
        guard engine.isRunning else { return }
        node.scheduleBuffer(buffer) { [weak self] in
            // Let go of the audio device once the sound has finished.
            //
            // This engine used to start on the first chime and stay running for the
            // rest of the session — a second AVAudioEngine holding the same output
            // device as the capture engine, which has voice processing on it during
            // a conversation. Two engines contending for one device is what the
            // crackling is. The chime is a fifth of a second; there is no reason to
            // hold the hardware for the hour afterwards.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                self?.releaseIfIdle()
            }
        }
        if !node.isPlaying { node.play() }
    }

    /// Shuts down once nothing is queued. Called a moment after each sound.
    private func releaseIfIdle() {
        guard started, !node.isPlaying else { return }
        node.stop()
        engine.stop()
        started = false
    }

    private func make(_ earcon: Earcon, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let samples = earcon.render(sampleRate: Self.rate)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            channel.update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    func stop() {
        node.stop()
        engine.stop()
        started = false
    }
}
