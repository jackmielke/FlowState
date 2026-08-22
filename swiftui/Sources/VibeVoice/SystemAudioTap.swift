import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import VibeVoiceCore

/// The speakers, as they actually sounded.
///
/// This is the difference between a recording and a re-enactment. The first version of
/// the recorder built its audio track out of the two streams the app already had: the
/// microphone buffers it was sending to OpenAI, and the audio packets OpenAI sent back.
/// Mixed together those sound roughly like the conversation, and they are wrong in ways
/// that matter:
///
///  * A reply the user talked over is *received* in full and *played* for half a second.
///    The tee records the whole thing, so the recording has the assistant calmly
///    finishing a sentence nobody heard.
///  * Volume, muting, the system output device, another app's audio ducking ours —
///    none of it exists in the tee. The recording is of a conversation that happened in
///    a parallel machine where all of that went differently.
///  * Anything else making noise at the time — a video, a notification, music — is
///    absent, so a screen recording of something with sound is silent.
///
/// ScreenCaptureKit will hand over the system mix instead, which has all of that in it
/// by construction, because it *is* what came out. The microphone half still comes from
/// the app's own tap: it is already echo-cancelled there, and taking it from the system
/// mix would put the assistant's voice in twice.
enum SystemAudioTap {

    /// What SCK is asked for. 48 kHz is the system mix's native rate — asking for
    /// anything else makes CoreAudio resample on the capture thread for no benefit,
    /// since this is downsampled to the recorder's rate here anyway.
    static let captureRate = 48_000

    /// Mono `Int16` at `SessionRecorder.sampleRate`, or nil if the buffer carried nothing.
    ///
    /// Downmixed by averaging rather than by taking the left channel: a stereo source
    /// with anything panned hard — a notification, a game, music — would otherwise lose
    /// half of itself, silently.
    static func decode(_ sampleBuffer: CMSampleBuffer) -> [Int16]? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return nil }

        guard let list = try? sampleBuffer.withAudioBufferList(blockBufferMemoryAllocator: nil, body: { list, _ in
            channels(from: list, asbd: asbd)
        }), !list.isEmpty else { return nil }

        let mono = downmix(list)
        guard !mono.isEmpty else { return nil }
        return resample(mono,
                        from: Int(asbd.mSampleRate),
                        to: SessionRecorder.sampleRate)
    }

    /// One `[Float]` per channel. SCK delivers 32-bit float, deinterleaved — the common
    /// case — but interleaved is handled too rather than returning silence if that ever
    /// changes underneath us.
    private static func channels(from list: UnsafeMutableAudioBufferListPointer,
                                 asbd: AudioStreamBasicDescription) -> [[Float]] {
        guard asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return [] }
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        if interleaved {
            guard let buf = list.first, let data = buf.mData else { return [] }
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let stride = Int(asbd.mChannelsPerFrame)
            guard stride > 0 else { return [] }
            let flat = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
            return (0..<stride).map { c in
                Swift.stride(from: c, to: count, by: stride).map { flat[$0] }
            }
        }

        return list.compactMap { buf in
            guard let data = buf.mData else { return nil }
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { return nil }
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        }
    }

    private static func downmix(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return first }
        let n = channels.map(\.count).min() ?? 0
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        for c in channels {
            for i in 0..<n { out[i] += c[i] }
        }
        let scale = 1 / Float(channels.count)
        for i in 0..<n { out[i] *= scale }
        return out
    }

    /// Linear resample to the recorder's rate, then to `Int16` with clipping.
    ///
    /// Linear rather than something with a proper filter because this is 48 k to 24 k —
    /// an exact 2:1 ratio in practice — and the aliasing a linear kernel leaves at that
    /// ratio is well below what a voice recording resolves. If the rates ever stop being
    /// related by a small integer this deserves a real filter.
    private static func resample(_ input: [Float], from: Int, to: Int) -> [Int16] {
        guard from > 0, to > 0, !input.isEmpty else { return [] }
        guard from != to else { return input.map(clamp) }
        let ratio = Double(from) / Double(to)
        let count = Int(Double(input.count) / ratio)
        guard count > 0 else { return [] }
        var out = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let x = Double(i) * ratio
            let lo = Int(x)
            let hi = Swift.min(lo + 1, input.count - 1)
            let t = Float(x - Double(lo))
            out[i] = clamp(input[lo] * (1 - t) + input[hi] * t)
        }
        return out
    }

    private static func clamp(_ v: Float) -> Int16 {
        let scaled = v * 32_767
        if scaled >= 32_767 { return .max }
        if scaled <= -32_768 { return .min }
        return Int16(scaled)
    }
}
