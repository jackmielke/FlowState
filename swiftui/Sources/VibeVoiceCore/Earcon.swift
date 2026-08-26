import Foundation

/// The small sounds an assistant makes about itself.
///
/// This app is used by somebody who is mostly not looking at it — that is the entire
/// point of a wake phrase — so the moments that matter most are the ones with no visual
/// feedback at all. Did it hear the clap. Is it listening now. Did it hang up, or crash.
/// A pill in a header answers none of those questions from across a room.
///
/// Synthesised rather than shipped as files: four sine tones with an envelope are a few
/// lines and no assets, they scale to any sample rate, and there is nothing to license,
/// forget to include in the bundle, or have somebody replace with an air horn.
///
/// They are deliberately quiet, short, and made of two notes. Two notes have a direction —
/// up is arriving, down is leaving — and direction is what makes a sound mean something
/// rather than merely happen.
public struct Earcon: Equatable, Sendable {

    /// Frequencies in Hz, played in order.
    public let notes: [Double]
    /// Seconds per note.
    public let noteLength: Double
    /// 0...1, before the envelope.
    public let level: Double

    public init(notes: [Double], noteLength: Double = 0.09, level: Double = 0.16) {
        self.notes = notes
        self.noteLength = noteLength
        self.level = level
    }

    /// E5 then A5 — a rising fourth, the most unambiguous "I'm here" interval there is.
    public static let wake = Earcon(notes: [659.25, 880.00])
    /// The same interval, falling. It is deliberately the wake sound backwards: leaving
    /// should sound like the opposite of arriving, not like a different event.
    public static let sleep = Earcon(notes: [880.00, 659.25], level: 0.13)
    /// One note, lower and softer — an acknowledgement, not an announcement. For the
    /// moment it starts listening to a specific request.
    public static let heard = Earcon(notes: [587.33], noteLength: 0.07, level: 0.10)
    /// A minor second down. Unresolved on purpose: it should sit slightly wrong.
    public static let trouble = Earcon(notes: [493.88, 466.16], noteLength: 0.11, level: 0.14)

    /// Dictation opening — the key went down and the microphone is live.
    ///
    /// The quietest and shortest sound in the app, by a distance, and that is the whole
    /// design. Every other earcon marks something that happens a few times an hour; this
    /// one fires every time a sentence is spoken, which in real use is dozens of times a
    /// minute. At `heard`'s level it would stop being feedback and start being a tic.
    /// C5, one note, barely there — you should notice its absence more than its presence.
    public static let dictateOpen = Earcon(notes: [523.25], noteLength: 0.05, level: 0.06)

    /// Dictation closing — key released, the words are on their way.
    ///
    /// A step down from `dictateOpen` rather than the same note, so that holding and
    /// releasing are distinguishable without looking. Softer again, because by this point
    /// you already know you were talking.
    public static let dictateClose = Earcon(notes: [440.00], noteLength: 0.05, level: 0.05)

    public var duration: Double { noteLength * Double(notes.count) }

    /// The waveform, as floats in -1...1.
    ///
    /// The envelope is the whole job. A tone that starts and ends at full amplitude
    /// clicks — a step from silence is broadband noise, and it is the difference between
    /// a sound that feels designed and one that feels like a fault. Each note is faded in
    /// and out, and the fade is a raised cosine rather than a line because a linear ramp
    /// still leaves a corner in the waveform.
    public func render(sampleRate: Double) -> [Float] {
        guard sampleRate > 0, !notes.isEmpty else { return [] }
        let perNote = Int(noteLength * sampleRate)
        guard perNote > 2 else { return [] }
        // 8 ms, or a quarter of the note if it is very short.
        let fade = max(1, min(perNote / 4, Int(0.008 * sampleRate)))

        var out = [Float]()
        out.reserveCapacity(perNote * notes.count)

        for note in notes {
            // Continue the phase across the note boundary rather than restarting it: a
            // phase jump between two notes is the same click, in the middle.
            var phase = 0.0
            let step = 2 * Double.pi * note / sampleRate
            for i in 0..<perNote {
                let envelope: Double
                if i < fade {
                    envelope = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fade))
                } else if i >= perNote - fade {
                    let k = Double(perNote - 1 - i) / Double(fade)
                    envelope = 0.5 - 0.5 * cos(Double.pi * k)
                } else {
                    envelope = 1
                }
                out.append(Float(sin(phase) * envelope * level))
                phase += step
            }
        }
        return out
    }
}

extension Earcon {

    /// The same waveform as a self-contained 16-bit mono WAV.
    ///
    /// This exists because of where dictation's sounds have to play. `AudioEngine.playTone`
    /// bails unless the conversation engine is already running, which is exactly the case
    /// dictation is *not* in — you hold the key while idle. The obvious fix, a second
    /// `AVAudioEngine` for chimes, is the one thing the audio notes in this repo warn
    /// against: two engines on one output device, one of them carrying a voice-processing
    /// unit, is where the system-wide crackle came from.
    ///
    /// `AVAudioPlayer` holds no engine and no audio unit — it is handed bytes and plays
    /// them — so producing bytes here sidesteps the whole class of problem. Pure, and
    /// therefore testable, which is the other reason it lives in this module.
    public func wavData(sampleRate: Double) -> Data {
        let samples = render(sampleRate: sampleRate)
        let rate = UInt32(sampleRate)
        let bytesPerSample: UInt32 = 2
        let dataBytes = UInt32(samples.count) * bytesPerSample

        var out = Data()
        func ascii(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }

        ascii("RIFF")
        u32(36 + dataBytes)          // everything after this field
        ascii("WAVE")
        ascii("fmt ")
        u32(16)                      // PCM header length
        u16(1)                       // format: uncompressed PCM
        u16(1)                       // mono
        u32(rate)
        u32(rate * bytesPerSample)   // byte rate
        u16(UInt16(bytesPerSample))  // block align
        u16(16)                      // bits per sample
        ascii("data")
        u32(dataBytes)

        for sample in samples {
            // Clamp before scaling. Float samples are nominally in -1...1, but the
            // envelope arithmetic can overshoot by a hair, and a value that wraps around
            // Int16 turns a quiet chime into a loud crack — the exact opposite of subtle.
            let clamped = max(-1.0, min(1.0, sample))
            u16(UInt16(bitPattern: Int16(clamped * 32767.0)))
        }
        return out
    }
}
