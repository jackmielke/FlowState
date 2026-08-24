import Foundation
import AVFoundation
import Combine
import os
import VibeVoiceCore

/// Records a conversation — both halves — to a single playable file.
///
/// Nothing new is captured to do this. Both sides already pass through the app as PCM16
/// at 24 kHz: your microphone on its way out, the model's voice on its way in. The
/// recorder tees those two streams and mixes them, so it costs no extra permission, no
/// extra API call and no re-encoding.
///
/// The mic is the clock. It runs continuously while connected, so its sample count is a
/// reliable timeline; the model's voice arrives in bursts and is mixed in at wherever the
/// timeline stands when it lands. That is within a buffer or two of where it was actually
/// heard, which is what matters for something you are going to listen back to.
///
/// The output is a plain 16-bit PCM WAV. It is bigger than an m4a and it plays absolutely
/// everywhere, with no encoder to go wrong halfway through a demo.
///
/// VIDEO
/// When the capture mode asks for pictures too, none of the above changes. The mic is
/// still the clock, the mixdown is still the mixdown, and the samples still end up in one
/// file — that file is a QuickTime movie rather than a WAV, and the writing of it is
/// handed to a `RecordingVideoTrack` (see `VideoTrackWriter`) so that ScreenCaptureKit and
/// AVAssetWriter stay on the other side of the wall. That wall is load-bearing: this file
/// imports nothing but Foundation, AVFoundation, Combine, os and VibeVoiceCore, which is
/// what lets `Scripts/verify-recorder.sh` compile it on its own and prove it still records.
///
/// THREADING
/// `appendMic` is called from the real-time audio thread — `AudioEngine.onMicPCM` fires
/// inside the capture tap — while `appendAssistant`, `start` and `stop` are called from
/// the main actor. So the sample buffer lives under a lock and the `@Published` mirrors
/// are refreshed from a main-thread timer rather than written wherever a buffer happens
/// to land. Marking this `@MainActor` instead would mean either hopping the actor forty
/// times a second from a real-time thread, or (as it did) never feeding it the mic at all.
final class SessionRecorder: ObservableObject, @unchecked Sendable {

    /// What a pause or a resume actually did. Same reasoning as `StopOutcome`: a caller
    /// about to say a sentence out loud needs to know which of these happened, and "it
    /// returned false" collapses three of them into one.
    enum PauseOutcome: Equatable {
        case paused(at: TimeInterval)
        case resumed(at: TimeInterval)
        /// Nothing is being recorded, so there is nothing to pause or continue.
        case notRecording
        /// Already in that state. Not a failure — somebody said it twice.
        case unchanged(paused: Bool)
    }

    /// Everything a caller needs to say what happened, instead of guessing from a nil.
    enum StopOutcome: Equatable {
        case saved(url: URL, seconds: TimeInterval)
        /// Captured something, but less than `minimumSeconds` of it.
        case tooShort(seconds: TimeInterval)
        /// The clock ran but no samples ever arrived — the symptom of an unwired tap.
        case captureNeverStarted(elapsed: TimeInterval)
        case writeFailed(reason: String)
        case notRecording
    }

    @Published private(set) var isRecording = false
    /// Recording, but taking nothing in. See `setPaused`.
    @Published private(set) var isPaused = false
    @Published private(set) var startedAt: Date?
    /// Seconds captured so far, derived from samples rather than the wall clock, so it
    /// reports what is actually in the file.
    @Published private(set) var duration: TimeInterval = 0
    /// Set when a start or a stop did not do what the button implied. Cleared on the
    /// next successful start, so it never outlives the problem it describes.
    @Published private(set) var lastError: String?

    private let lock = NSLock()
    private var samples: [Int16] = []
    private var cursor = 0          // where the mic has written up to
    private var url: URL?
    /// Counted separately from `samples.count` so "the tap is silent" and "the tap is
    /// unwired" are distinguishable — silence still arrives as buffers of zeroes.
    private var micChunks = 0
    private var assistantChunks = 0

    /// Refreshes the published mirrors. Four times a second is enough for a mm:ss clock
    /// and cheap enough to leave running for an hour.
    private var uiTimer: Timer?

    /// Who writes the pictures, for as long as there are pictures to write. Nil for an
    /// audio-only recording, which is the default and every recording made before this
    /// existed. Guarded by `lock` like everything else the audio thread can race.
    private var videoTrack: RecordingVideoTrack?

    /// What this take is capturing. Read by the UI for the live storage estimate, so it
    /// outlives `stop` rather than being cleared with the rest of the state — the panel
    /// that appears after a recording still has to describe what was captured.
    private(set) var capturePlan: CapturePlan = CapturePlan.make(mode: .audioOnly, profile: .balanced)

    static let sampleRate = 24_000
    /// Below this a file is a click, not a recording.
    static let minimumSeconds: TimeInterval = 0.25

    private static let log = Logger(subsystem: "com.jackmielke.vibevoice", category: "recorder")

    /// Where recordings are kept. Pure — it creates nothing, so a caller is allowed to
    /// ask whether the folder is actually there. `directory` used to be the only way to
    /// name it and made the folder as a side effect, which meant "does it exist?" was a
    /// question that answered itself yes.
    static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeVoice/Recordings", isDirectory: true)
    }

    /// The same folder, brought into existence. For the write path only.
    static var directory: URL {
        let base = directoryURL
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - Lifecycle

    /// - Parameters:
    ///   - title: what the conversation is about. Becomes part of the file name; see
    ///     `RecordingName` for what happens to a title with a slash or a newline in it.
    ///   - plan: what is being captured and how. The default is the original behaviour —
    ///     audio only, written as a WAV — so every existing caller is unchanged.
    ///   - video: the thing that writes the pictures, when there are pictures. Required
    ///     for a video plan and ignored for an audio one, rather than optional for both:
    ///     starting a screen recording with nothing to write it to would go red, run, and
    ///     produce a silent nothing, which is the exact failure the outcome enum exists
    ///     to make impossible.
    @discardableResult
    func start(title: String,
               plan: CapturePlan = CapturePlan.make(mode: .audioOnly, profile: .balanced),
               video: RecordingVideoTrack? = nil) -> URL? {
        lock.lock()
        if isRecordingLocked {
            let existing = url
            lock.unlock()
            Self.log.notice("start ignored — already recording")
            return existing
        }

        let name = RecordingName.fileName(title: title, date: Date(), mode: plan.mode)
        let target = Self.directory.appendingPathComponent(name)

        if plan.mode.isVideo {
            guard let video else {
                lock.unlock()
                let why = "\(plan.mode.menuLabel) needs a video writer, and none was supplied."
                Self.log.error("\(why, privacy: .public)")
                publish(isRecording: false, startedAt: nil, duration: 0, error: why)
                return nil
            }
            do {
                try video.begin(destination: target, plan: plan)
            } catch {
                lock.unlock()
                let why = "Could not start the video recording: \(error.localizedDescription)"
                Self.log.error("\(why, privacy: .public)")
                publish(isRecording: false, startedAt: nil, duration: 0, error: why)
                return nil
            }
        }

        samples.removeAll(keepingCapacity: true)
        cursor = 0
        micChunks = 0
        assistantChunks = 0
        assistantTimeline.reset()
        hasSystemAudio = false
        systemAudioChunks = 0
        url = target
        // Held for the whole recording, and only for a video plan — `stop` uses its
        // presence, not the plan's, to decide who writes the file.
        videoTrack = plan.mode.isVideo ? video : nil
        capturePlan = plan
        isRecordingLocked = true
        isPausedLocked = false
        lock.unlock()

        Self.log.notice("start → \(target.lastPathComponent, privacy: .public) [\(plan.mode.rawValue, privacy: .public)]")
        publish(isRecording: true, startedAt: Date(), duration: 0, error: nil)
        startClock()
        return target
    }

    /// Stops taking anything in, without ending the take.
    ///
    /// A pause is a SPLICE, not a gap. Everything fed while paused is dropped on the
    /// floor — mic, model, speakers, frames — so what resumes lands immediately after
    /// what came before it, and a recording paused for ten minutes is ten minutes
    /// shorter rather than ten minutes of silence in the middle. That is what somebody
    /// who says "pause recording" means, and it is also the only version that keeps the
    /// two halves of the file aligned: the mixdown's clock is the mic, so time the mic
    /// does not contribute is time the video must not contribute either. The video
    /// writer is told, and shifts its own timestamps by the same amount — see
    /// `VideoTrackWriter.setPaused`.
    ///
    /// Deliberately not implemented as stop-and-start-a-second-file. One recording is one
    /// file; "pause" that quietly produced three files in the Recordings folder would be
    /// a worse answer than refusing to pause at all.
    @discardableResult
    func setPaused(_ paused: Bool) -> PauseOutcome {
        lock.lock()
        guard isRecordingLocked else {
            lock.unlock()
            Self.log.notice("\(paused ? "pause" : "resume", privacy: .public) ignored — not recording")
            return .notRecording
        }
        guard paused != isPausedLocked else {
            lock.unlock()
            return .unchanged(paused: paused)
        }
        isPausedLocked = paused
        let seconds = Double(samples.count) / Double(Self.sampleRate)
        let video = videoTrack
        lock.unlock()

        // Outside the lock: this reaches into ScreenCaptureKit's clock, and the audio
        // thread must never wait on that.
        video?.setPaused(paused)

        Self.log.notice("""
            \(paused ? "paused" : "resumed", privacy: .public) at \
            \(seconds, format: .fixed(precision: 2))s
            """)
        FileHandle.standardError.write(Data(
            "[recorder] \(paused ? "paused" : "resumed") at \(String(format: "%.2f", seconds))s\n".utf8))

        let apply = { [weak self] in
            guard let self else { return }
            self.isPaused = paused
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }

        return paused ? .paused(at: seconds) : .resumed(at: seconds)
    }

    /// Finishes and writes the file.
    ///
    /// Every failure is named. "Returns nil" was the old contract and it collapsed four
    /// different problems — never started, never fed, too short, disk error — into one
    /// silent nothing, which is exactly how a recorder can show red, capture zero
    /// seconds and leave the user with no idea which part broke.
    @discardableResult
    func stop() -> StopOutcome {
        lock.lock()
        guard isRecordingLocked else {
            lock.unlock()
            Self.log.notice("stop ignored — not recording")
            return .notRecording
        }
        isRecordingLocked = false
        isPausedLocked = false
        let captured = samples
        let target = url
        let mic = micChunks
        let assistant = assistantChunks
        let speakers = systemAudioChunks
        let video = videoTrack
        samples.removeAll(keepingCapacity: false)
        cursor = 0
        url = nil
        videoTrack = nil
        lock.unlock()

        let began = startedAt
        let seconds = Double(captured.count) / Double(Self.sampleRate)
        let elapsed = began.map { Date().timeIntervalSince($0) } ?? 0
        stopClock()

        Self.log.notice("""
            stop — \(captured.count) samples (\(seconds, format: .fixed(precision: 2))s) \
            from \(mic) mic + \(assistant) assistant + \(speakers) speaker chunks over \
            \(elapsed, format: .fixed(precision: 1))s wall clock
            """)

        func finish(_ outcome: StopOutcome, error: String?) -> StopOutcome {
            publish(isRecording: false, startedAt: nil, duration: seconds, error: error)
            return outcome
        }

        /// Every path out of here that is not a saved file has to tear the video down.
        /// A stream left running is a camera light that stays on and a display that keeps
        /// being sampled after the user pressed stop — the most alarming possible way to
        /// report "that was too short to keep".
        func abandonVideo() {
            guard let video else { return }
            video.cancel()
            if let target { try? FileManager.default.removeItem(at: target) }
        }

        // No samples at all after a real stretch of wall clock means nothing was ever
        // teed into the recorder — a wiring fault, not a short recording, and worth
        // saying out loud because the two look identical from the button.
        if mic == 0 && assistant == 0 {
            // Under a second is someone double-clicking the button, and flagging that as
            // a fault would cry wolf. A second or more with nothing at all in it is the
            // wiring fault, and that one is worth shouting about.
            let fault = elapsed >= 1
            let why = fault
                ? "No audio ever reached the recorder — the microphone tap is not feeding it."
                : "Stopped before any audio arrived."
            if fault { Self.log.error("\(why, privacy: .public)") }
            else { Self.log.notice("\(why, privacy: .public)") }
            abandonVideo()
            return finish(.captureNeverStarted(elapsed: elapsed), error: fault ? why : nil)
        }

        guard let target else {
            abandonVideo()
            let why = "Recording had nowhere to be written."
            Self.log.error("\(why, privacy: .public)")
            return finish(.writeFailed(reason: why), error: why)
        }

        guard seconds >= Self.minimumSeconds else {
            abandonVideo()
            return finish(.tooShort(seconds: seconds), error: nil)
        }

        do {
            // One file either way. The movie writer is handed the same mixdown the WAV
            // would have contained — it is not fed a second, separately captured stream —
            // so the audio in a screen recording is bit-for-bit the audio you would have
            // got from the same conversation recorded audio-only.
            if let video {
                try video.finish(samples: captured, sampleRate: Self.sampleRate)
            } else {
                try Self.writeWAV(samples: captured, to: target)
            }
            Self.log.notice("saved \(target.lastPathComponent, privacy: .public)")
            return finish(.saved(url: target, seconds: seconds), error: nil)
        } catch {
            abandonVideo()
            let why = "Could not write \(target.lastPathComponent): \(error.localizedDescription)"
            Self.log.error("\(why, privacy: .public)")
            FileHandle.standardError.write(Data("[recorder] \(why)\n".utf8))
            return finish(.writeFailed(reason: why), error: why)
        }
    }

    // MARK: - Feeding

    /// The microphone, which also advances the timeline.
    ///
    /// Called on the audio thread. Everything it touches is under the lock, and nothing
    /// it touches is `@Published`.
    func appendMic(_ pcm16: Data) {
        let incoming = Self.toSamples(pcm16)
        guard !incoming.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard isRecordingLocked, !isPausedLocked else { return }
        write(incoming, at: cursor)
        cursor += incoming.count
        micChunks += 1
    }

    /// The speakers, at the moment they made the sound.
    ///
    /// When this is running it *replaces* `appendAssistant` rather than adding to it —
    /// the system mix already contains the model's voice, exactly as much of it as was
    /// actually played. That is the whole point: a reply the user talked over stops in
    /// the recording where it stopped in the room.
    ///
    /// - Parameter seconds: offset from the first system-audio buffer, from the capture
    ///   offset from the moment recording began, taken from the capture stream's own
    ///   host-clock timestamps — the same origin the video track uses. Not a count of
    ///   how much has arrived: a dropped buffer would pull everything after it earlier
    ///   and slide the two halves of the conversation apart for the rest of the file.
    func appendSystemAudio(_ samples: [Int16], at seconds: Double) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard isRecordingLocked, !isPausedLocked else { return }
        if !hasSystemAudio {
            hasSystemAudio = true
            Self.log.notice("speakers joined \(seconds, format: .fixed(precision: 3))s into the recording")
            FileHandle.standardError.write(Data("[recorder] speakers joined \(String(format: "%.3f", seconds))s into the recording\n".utf8))
        }
        write(samples, at: Int(seconds * Double(Self.sampleRate)))
        systemAudioChunks += 1
    }

    /// True once any speaker audio has arrived, which is what switches the model's own
    /// stream off. Latched rather than read from settings so that a capture that fails
    /// to produce audio — no output device, an unusual routing — silently falls back to
    /// the old behaviour instead of recording a conversation with one voice in it.
    private var hasSystemAudio = false
    private var systemAudioChunks = 0

    /// The model's voice, laid out on the timeline from where its current turn began.
    ///
    /// Not written at `cursor`. See `AssistantTimeline` — the socket delivers a reply
    /// much faster than it is spoken, so the mic head is the wrong place for every chunk
    /// after the first.
    func appendAssistant(_ pcm16: Data) {
        let incoming = Self.toSamples(pcm16)
        guard !incoming.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard isRecordingLocked, !isPausedLocked else { return }
        // The speakers are already being recorded; this stream would be a second, longer
        // copy of the same voice.
        guard !hasSystemAudio else { return }
        let at = assistantTimeline.reserve(count: incoming.count, micHead: cursor)
        write(incoming, at: at)
        assistantChunks += 1
    }

    /// The assistant's own write head. See `appendAssistant`.
    private var assistantTimeline = AssistantTimeline()

    /// Saturating mix of `incoming` into the buffer starting at `index`, growing it
    /// first. Caller holds the lock.
    private func write(_ incoming: [Int16], at index: Int) {
        if samples.count < index + incoming.count {
            samples.append(contentsOf: repeatElement(0, count: index + incoming.count - samples.count))
        }
        for (i, s) in incoming.enumerated() {
            samples[index + i] = Self.mix(samples[index + i], s)
        }
    }

    // MARK: - Published mirrors

    /// The authoritative flag, read and written under the lock. `isRecording` is its
    /// main-thread mirror and is what the views bind to.
    private var isRecordingLocked = false
    /// The pause flag, on the same side of the lock as `isRecordingLocked` and for the
    /// same reason: it is read from the audio thread on every buffer.
    private var isPausedLocked = false

    private func startClock() {
        stopClock()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let seconds = Double(self.samples.count) / Double(Self.sampleRate)
            let live = self.isRecordingLocked
            self.lock.unlock()
            guard live else { return }
            if abs(seconds - self.duration) > 0.001 { self.duration = seconds }
        }
        RunLoop.main.add(t, forMode: .common)
        uiTimer = t
    }

    private func stopClock() {
        uiTimer?.invalidate()
        uiTimer = nil
    }

    private func publish(isRecording: Bool, startedAt: Date?, duration: TimeInterval, error: String?) {
        let apply = { [weak self] in
            guard let self else { return }
            self.isRecording = isRecording
            // Nothing is ever published as paused: a pause is announced by `setPaused`,
            // and every other transition — start, stop, failure — ends with the take
            // running or gone.
            self.isPaused = false
            self.startedAt = startedAt
            self.duration = duration
            self.lastError = error
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    // MARK: -

    /// Saturating add. Two voices summing past Int16 would wrap to the opposite sign,
    /// which is heard as a loud click exactly when both people talk at once.
    private static func mix(_ a: Int16, _ b: Int16) -> Int16 {
        Int16(clamping: Int32(a) + Int32(b))
    }

    private static func toSamples(_ d: Data) -> [Int16] {
        guard d.count >= 2 else { return [] }
        return d.withUnsafeBytes { raw in
            // `bindMemory` requires the count to divide evenly; a half sample at the end
            // of a chunk would trap rather than be dropped.
            let usable = raw.count - (raw.count % MemoryLayout<Int16>.size)
            return Array(UnsafeRawBufferPointer(rebasing: raw[0..<usable]).bindMemory(to: Int16.self))
        }
    }

    /// A 44-byte canonical WAV header, then the samples.
    static func writeWAV(samples: [Int16], to url: URL) throws {
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        let rate = UInt32(sampleRate)
        let byteRate = rate * UInt32(channels) * UInt32(bits / 8)
        let blockAlign = channels * (bits / 8)
        let dataBytes = UInt32(samples.count * MemoryLayout<Int16>.size)

        var out = Data()
        func str(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }

        str("RIFF"); u32(36 + dataBytes); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(channels)
        u32(rate); u32(byteRate); u16(blockAlign); u16(bits)
        str("data"); u32(dataBytes)
        samples.withUnsafeBufferPointer { out.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self)) }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try out.write(to: url, options: .atomic)
    }

    // MARK: - Library

    struct Recording: Identifiable, Equatable {
        var id: String { url.path }
        var url: URL
        var createdAt: Date
        var bytes: Int
        var seconds: TimeInterval

        var title: String { url.deletingPathExtension().lastPathComponent }
        var lengthLabel: String {
            let s = Int(seconds)
            return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
        }
    }

    /// What is on disk, newest first.
    ///
    /// Filters on `RecordingName.knownExtensions` rather than on `wav`, which is what it
    /// used to do and which would have made every video recording invisible in Settings
    /// the day one was first written — correctly saved, correctly named, and absent from
    /// the only list in the app that shows recordings.
    static func library() async -> [Recording] {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys)) ?? []
        var out: [Recording] = []
        for u in urls where RecordingName.isRecording(u) {
            let v = try? u.resourceValues(forKeys: Set(keys))
            let bytes = v?.fileSize ?? 0
            out.append(Recording(url: u,
                                 createdAt: v?.creationDate ?? .distantPast,
                                 bytes: bytes,
                                 seconds: await length(of: u, bytes: bytes)))
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    /// How long a file on disk runs.
    ///
    /// A WAV is arithmetic — the header is 44 bytes and everything after it is 2 bytes a
    /// sample — and doing it that way costs one `stat` for the whole folder. A movie is
    /// not: its length lives in a `moov` atom that has to be parsed, so it is asked of
    /// AVFoundation — asynchronously, which is the only non-deprecated way to ask, and
    /// which is why the whole scan is async. That is a real file read per movie, so it is
    /// only done for the files that need it rather than for the whole list.
    private static func length(of url: URL, bytes: Int) async -> TimeInterval {
        guard url.pathExtension.lowercased() != "wav" else {
            return Double(max(0, bytes - 44)) / 2.0 / Double(sampleRate)
        }
        guard let duration = try? await AVURLAsset(url: url).load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        // A movie still being written, or a truncated one, reports NaN rather than
        // failing. Zero is the honest answer there: `RecordingFile.lengthLabel` shows
        // "0s", which is at least not a number someone can act on and be wrong.
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }
}


/// The other half of a video recording: whatever is writing the pictures.
///
/// `SessionRecorder` owns the timeline, the mixdown and every outcome the user is told
/// about. It deliberately knows nothing about ScreenCaptureKit, AVAssetWriter or the
/// camera — all of that lives behind this protocol, in `VideoTrackWriter`, on the other
/// side of a wall that exists so this file keeps compiling on its own under
/// `Scripts/verify-recorder.sh`.
///
/// The contract is small and strictly ordered:
///
///  1. `begin` once, before any audio is fed. It throws rather than failing quietly, so a
///     screen recording that cannot start never shows a red button.
///  2. Frames arrive on the implementation's own queues in the meantime. The recorder
///     neither sees them nor waits for them — a stalled capture must not stall the audio.
///  3. Exactly one of `finish` or `cancel`. `finish` is handed the completed mixdown and
///     is responsible for the audio track and for closing the file; `cancel` tears
///     everything down and leaves nothing behind.
///
/// `@unchecked Sendable` conformance is the implementation's problem, not this file's:
/// the recorder only ever touches it from the main actor, under the lock.
protocol RecordingVideoTrack: AnyObject {

    /// Open the file and start the capture. Throws if either cannot be done.
    func begin(destination: URL, plan: CapturePlan) throws

    /// Stop capturing, write `samples` as the audio track, and close the file.
    ///
    /// The audio is handed over whole, at the end, rather than streamed in as it arrives.
    /// That is deliberate: the model's voice is mixed into the timeline *retroactively* —
    /// see `write(_:at:)` — so a sample that has already been "written" can still change
    /// until the recording stops. Streaming it would put the earlier, unmixed version in
    /// the file.
    func finish(samples: [Int16], sampleRate: Int) throws

    /// Stop and restart the pictures without ending the file.
    ///
    /// Required rather than optional, and deliberately so. `SessionRecorder` drops every
    /// sample fed to it while paused, which shortens the mixdown by exactly the length of
    /// the pause — so a writer that quietly ignored this would keep stamping frames
    /// against a clock the audio no longer shares, and the file would drift further out
    /// of sync with every pause. A no-op default would make that the failure mode of any
    /// writer somebody forgets to update.
    func setPaused(_ paused: Bool)

    /// Tear down without producing a file. Must be safe to call after a failed `begin`,
    /// and must leave no capture running — a camera light that stays on after stop is the
    /// most alarming possible bug in this feature.
    func cancel()

    /// Bytes on disk so far, or 0 when that is not knowable yet. Drives the live storage
    /// meter, so it is asked for roughly once a second and must be cheap.
    var bytesWritten: Int { get }
}
