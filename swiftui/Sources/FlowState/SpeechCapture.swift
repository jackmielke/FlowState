import Foundation
import FlowStateCore

/// Measures the utterance the user is currently speaking, without keeping it.
///
/// The samples stream past on the audio thread on their way to the socket; this watches
/// them go by and remembers only the shape — how long, how loud, how many bytes. That is
/// the "store user audio as metadata" half of conversation memory, and it is the version
/// that can be on by default without anybody having to think about it.
///
/// Locked rather than main-actor isolated: `ingest` is called from the AVAudioEngine tap
/// thread, roughly every 20 ms, and hopping to the main queue for a running total would
/// be both wasteful and a correctness hazard. Same shape as `LevelBox` above it in the
/// audio path.
final class UtteranceRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private var startedAt: Date?
    private var byteCount = 0
    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var sampleCount = 0
    /// Set only when clip recording is explicitly on. See `AudioClipRecorder`.
    private var clipPath: String?

    private let sampleRate: Double

    init(sampleRate: Double = AudioEngine.targetRate) {
        self.sampleRate = sampleRate
    }

    /// Server VAD says the user started talking.
    func begin(at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        startedAt = date
        byteCount = 0
        peak = 0
        sumSquares = 0
        sampleCount = 0
        clipPath = nil
    }

    /// One chunk of mono PCM16 @ 24 kHz, on the audio thread.
    ///
    /// Cheap by construction: a running sum over Int16s, no allocation, no copy. If this
    /// ever needs to do more than arithmetic, it belongs off this thread.
    func ingest(pcm16: Data) {
        lock.lock(); defer { lock.unlock() }
        // Nothing between utterances is worth measuring — server VAD has already decided
        // it is not speech, and counting it would inflate every duration by the silence
        // around it.
        guard startedAt != nil else { return }

        byteCount += pcm16.count
        pcm16.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            for s in samples {
                let v = Float(Int16(littleEndian: s)) / 32768.0
                let a = abs(v)
                if a > peak { peak = a }
                sumSquares += Double(v) * Double(v)
            }
            sampleCount += samples.count
        }
    }

    /// Server VAD says they stopped. Returns what was measured, and forgets it.
    func end(at date: Date = Date()) -> UtteranceAudio? {
        lock.lock(); defer { lock.unlock() }
        guard let started = startedAt else { return nil }
        startedAt = nil

        // Prefer the sample count over the wall clock: it is what actually reached the
        // model, and it does not drift if the audio thread stalls.
        let duration = sampleCount > 0 ? Double(sampleCount) / sampleRate
                                       : date.timeIntervalSince(started)
        let rms = sampleCount > 0 ? Float((sumSquares / Double(sampleCount)).squareRoot()) : 0

        return UtteranceAudio(startedAt: started,
                              duration: duration,
                              sampleRate: sampleRate,
                              channels: 1,
                              byteCount: byteCount,
                              peakLevel: peak,
                              averageLevel: rms,
                              clipPath: clipPath)
    }

    /// Throws away whatever is in progress. Used on disconnect, so a half-measured
    /// utterance cannot attach itself to the first line of the next session.
    func discard() {
        lock.lock(); defer { lock.unlock() }
        startedAt = nil
        sampleCount = 0
        byteCount = 0
    }
}

// MARK: - Where a real transcriber goes

/// The seam for transcribing the user's speech.
///
/// Today exactly one implementation is live: the realtime API already returns the user's
/// words on the socket it is streaming their audio to, so asking a second service to
/// transcribe the same audio would cost twice and disagree with itself. `RealtimeAPI`
/// therefore does not transcribe anything — it names the path that is already wired, so
/// entries can record where their text came from.
///
/// A second implementation would be wanted the moment the user wants transcripts with
/// the socket closed (dictation, offline notes), and that is what `LocalTranscriber` is
/// a placeholder for.
protocol UserTranscriber: AnyObject {
    var source: TranscriptSource { get }
    /// Returns nil when this transcriber is not the one producing the text.
    func transcribe(_ audio: UtteranceAudio) async -> String?
}

/// The live path. The socket delivers
/// `conversation.item.input_audio_transcription.completed`; see
/// `RealtimeClient.handle` and `AppState.handle(.userTranscript)`.
final class RealtimeAPITranscriber: UserTranscriber {
    let source: TranscriptSource = .realtimeAPI
    func transcribe(_ audio: UtteranceAudio) async -> String? { nil }
}

/// PLACEHOLDER — on-device transcription.
///
/// This is the injection point, and nothing here talks to a recogniser. A real
/// implementation would need the samples, which means two changes, both deliberate
/// rather than incidental:
///
///  1. Microphone routing: `AudioEngine.onMicPCM` is currently the only tap on the
///     capture path and it hands each chunk straight to the socket. A second consumer
///     would be added there (a `onMicPCMSecondary` closure, or a small fan-out), so the
///     recogniser gets the same 24 kHz mono PCM16 without the socket losing a frame.
///  2. A recogniser: `SFSpeechRecognizer` with an `SFSpeechAudioBufferRecognitionRequest`
///     is the no-new-dependency option on macOS and needs an `NSSpeechRecognitionUsageDescription`
///     in Info.plist plus a TCC prompt. A bundled whisper build is the offline option and
///     needs the samples buffered to a file first.
///
/// Until one of those exists this returns a stand-in that is obviously a stand-in, so a
/// transcript built from it can never be mistaken for the real thing.
final class LocalTranscriber: UserTranscriber {
    let source: TranscriptSource = .placeholder

    func transcribe(_ audio: UtteranceAudio) async -> String? {
        guard audio.duration > 0.2, !audio.isSilent else { return nil }
        return String(format: "[untranscribed speech, %.1fs]", audio.duration)
    }
}

/// PLACEHOLDER — writing microphone audio to disk.
///
/// Kept as a named type with a hard refusal in it rather than as a TODO comment, because
/// "where would the audio be written" should have exactly one answer, and that answer
/// should be a file that currently refuses to write anything.
///
/// A real implementation would open an `AVAudioFile` at
/// `~/Library/Application Support/FlowState/audio/<sessionID>/<utterance>.caf` on
/// `begin`, append each converted buffer, close on `end`, and return the path for
/// `UtteranceAudio.clipPath`. It must honour `TranscriptPrivacy.keepAudioClips` on every
/// single call — not once at construction — because the user can turn it off mid-session
/// and expect that to take effect immediately.
enum AudioClipRecorder {

    /// The directory clips would live in. Created lazily, and only by a real recorder.
    ///
    /// Under `ConversationStore.root` rather than reaching for Application Support
    /// directly, so it moves with `VIBEVOICE_HOME` like everything else FlowState keeps.
    /// It did not, which meant "delete everything" pointed at the real folder even
    /// during a test run over a temporary home.
    static var directory: URL {
        ConversationStore.root.appendingPathComponent("audio", isDirectory: true)
    }

    /// Returns the path a clip was written to, or nil.
    ///
    /// Always nil today. The privacy check is written out anyway so that the first thing
    /// a real implementation inherits is the refusal.
    static func write(pcm16: Data, sessionID: String, privacy: TranscriptPrivacy) -> String? {
        guard privacy.keepAudioClips, !privacy.paused else { return nil }
        // Real implementation goes here. Deliberately not writing audio the user has not
        // been asked about in a build where the toggle has no UI consequences yet.
        return nil
    }
}
