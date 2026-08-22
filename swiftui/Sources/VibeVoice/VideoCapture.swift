import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreImage
import CoreVideo
import CoreMedia
import Metal
import os
import VibeVoiceCore

/// Everything that can go wrong on the way to a movie, named.
///
/// Same principle as `SessionRecorder.StopOutcome`: a video recorder that fails by
/// returning nothing produces a red button, a running fan and no file, and the user has
/// no way to tell which of five things broke.
enum VideoCaptureError: LocalizedError {
    case noDisplay
    case noCamera(String)
    case cameraDenied
    case writerRefused(String)
    case streamFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noDisplay:            return "No display was available to record."
        case .noCamera(let why):    return "No camera was available to record — \(why)."
        case .cameraDenied:         return "Camera access is off for \(kSystemAppName). Turn it on in \(CapturePermission.camera.settingsPath)."
        case .writerRefused(let w): return "The movie file could not be opened: \(w)"
        case .streamFailed(let w):  return "Screen capture stopped: \(w)"
        case .cancelled:            return "The recording was cancelled."
        }
    }
}

/// Writes the picture half of a recording.
///
/// One file, one video track, one audio track. The audio is `SessionRecorder`'s mixdown,
/// handed over whole at the end (see `RecordingVideoTrack.finish`); the video is whichever
/// of the two sources the mode asked for, composited when it asked for both.
///
/// WHERE THE FRAMES COME FROM
/// ScreenCaptureKit is asked for frames at exactly the plan's size and frame rate, so the
/// common case — a screen recording, no camera — never touches Core Image at all: the
/// pixel buffer SCK hands over is the pixel buffer that goes into the file. The camera is
/// asked for its frames pre-scaled the same way. Only `.full` composites, because only
/// `.full` has two pictures to put in one frame.
///
/// WHAT IS NOT WRITTEN
/// SCK reports frames that are *idle* — the screen has not changed since the last one —
/// and those are dropped rather than encoded. A movie with a gap in it is not a broken
/// movie: the previous frame simply stays on screen for longer, which is exactly what
/// happened. It is also most of why a recording of someone reading a document is a
/// fraction of the estimated size.
///
/// THREADING
/// `begin`, `finish` and `cancel` are called from the main actor, inside
/// `SessionRecorder`'s lock. Frames arrive on two private serial queues and never touch
/// the main actor. The state they share is guarded by `lock`.
final class VideoTrackWriter: NSObject, RecordingVideoTrack, @unchecked Sendable {

    private static let log = Logger(subsystem: "com.jackmielke.vibevoice", category: "video-capture")

    /// Told when the capture dies on its own — a display unplugged, permission revoked
    /// mid-recording, the encoder giving up. Without it those failures are silent until
    /// the user stops and finds a movie that ends early.
    var onFailure: ((String) -> Void)?

    /// Which display to record, and which camera. Resolved by `AppState` from settings
    /// before the recording starts, so this class never has to guess.
    var displayID: CGDirectDisplayID?
    var cameraID: String?

    // MARK: - State

    private let lock = NSLock()

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var plan = CapturePlan.make(mode: .audioOnly, profile: .balanced)
    private var destination: URL?
    private var sessionStart = CMTime.zero
    private var lastFrameTime: CMTime?
    private var framesWritten = 0
    private var framesDropped = 0
    private var failed: String?

    private var stream: SCStream?
    private var session: AVCaptureSession?
    /// The most recent camera frame, for `.full` to draw into the corner. Held rather
    /// than queued: a composite is only ever as fresh as the screen frame it is drawn
    /// onto, so anything older than "the latest" is of no use to anybody.
    private var latestCamera: CVPixelBuffer?

    private let screenQueue = DispatchQueue(label: "com.jackmielke.vibevoice.video.screen")
    private let cameraQueue = DispatchQueue(label: "com.jackmielke.vibevoice.video.camera")
    private let audioQueue = DispatchQueue(label: "com.jackmielke.vibevoice.video.audio")

    /// Built once. A `CIContext` compiles and caches its render pipeline, so making one
    /// per frame is the single most expensive mistake available in this file.
    private lazy var ci: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    // MARK: - RecordingVideoTrack

    func begin(destination target: URL, plan wanted: CapturePlan) throws {
        lock.lock()
        plan = wanted
        destination = target
        framesWritten = 0
        framesDropped = 0
        failed = nil
        lastFrameTime = nil
        latestCamera = nil
        lock.unlock()

        // A leftover file at the same path makes AVAssetWriter refuse to start, and the
        // name carries a minute-resolution stamp — so two recordings started in the same
        // minute is a real, reachable case rather than a theoretical one.
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: target, fileType: .mov)
        } catch {
            throw VideoCaptureError.writerRefused(error.localizedDescription)
        }

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(for: wanted))
        // The frames arrive from a live capture, so the encoder must not be allowed to
        // block waiting for them.
        video.expectsMediaDataInRealTime = true

        // The audio is pushed in one go after the capture has stopped, so this one is
        // explicitly NOT real-time: it is allowed to make the writer wait.
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings())
        audio.expectsMediaDataInRealTime = false

        guard writer.canAdd(video), writer.canAdd(audio) else {
            throw VideoCaptureError.writerRefused("the movie cannot hold these tracks")
        }
        writer.add(video)
        writer.add(audio)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: wanted.width,
                kCVPixelBufferHeightKey as String: wanted.height,
                // Without an IOSurface the composite path copies every frame through
                // main memory instead of handing the GPU a shared surface.
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ])

        guard writer.startWriting() else {
            throw VideoCaptureError.writerRefused(writer.error?.localizedDescription ?? "unknown reason")
        }

        // The host clock is the one both ScreenCaptureKit and AVCaptureSession stamp
        // their buffers with, so starting the session on it means no frame ever needs
        // re-timing — and the audio, which has no clock of its own, can simply be laid
        // down from this instant forward.
        let start = CMClockGetTime(CMClockGetHostTimeClock())
        writer.startSession(atSourceTime: start)

        lock.lock()
        self.writer = writer
        self.videoInput = video
        self.audioInput = audio
        self.adaptor = adaptor
        self.sessionStart = start
        lock.unlock()

        if wanted.mode.capturesCamera { try startCamera(plan: wanted) }
        if wanted.mode.capturesScreen { startScreen(plan: wanted) }

        Self.log.notice("""
            begin \(target.lastPathComponent, privacy: .public) — \
            \(wanted.summary, privacy: .public) @ \(wanted.videoBitRate / 1000, privacy: .public) kbps
            """)
    }

    func finish(samples: [Int16], sampleRate: Int) throws {
        stopSources()

        lock.lock()
        let writer = self.writer
        let video = self.videoInput
        let audio = self.audioInput
        let start = sessionStart
        let wrote = framesWritten
        let dropped = framesDropped
        let problem = failed
        lock.unlock()

        guard let writer, let video, let audio else { throw VideoCaptureError.cancelled }

        video.markAsFinished()

        // A capture that died halfway is still worth keeping — the part before it died is
        // real — but the user has to be told, and the recorder's own outcome cannot say
        // it, so it goes in the log and through `onFailure`.
        if let problem { Self.log.error("finishing a recording that failed: \(problem, privacy: .public)") }

        try writeAudioTrack(samples: samples, sampleRate: sampleRate, into: audio, from: start)

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        // Blocking the main thread, on purpose and briefly: this writes the index at the
        // end of the file, which is milliseconds even for an hour of video, and the
        // alternative is a "saved" panel that appears before the file is playable.
        // Bounded rather than infinite — a hung encoder must not hang the app.
        if done.wait(timeout: .now() + 30) == .timedOut {
            throw VideoCaptureError.writerRefused("the encoder did not finish within 30 seconds")
        }

        if writer.status == .failed {
            throw VideoCaptureError.writerRefused(writer.error?.localizedDescription ?? "unknown reason")
        }

        Self.log.notice("finished — \(wrote, privacy: .public) frames written, \(dropped, privacy: .public) dropped")
        clear()
    }

    func cancel() {
        stopSources()
        lock.lock()
        let writer = self.writer
        lock.unlock()
        // `cancelWriting` deletes the partial file for us, which is the behaviour we want
        // everywhere `cancel` is called: nothing left behind to be found later and
        // mistaken for a recording.
        if writer?.status == .writing { writer?.cancelWriting() }
        clear()
    }

    /// What is on disk so far. Asked about once a second by the storage meter, so it is a
    /// single `stat` and nothing more — AVAssetWriter grows the file as it goes, so this
    /// is a real measurement rather than the estimate the meter would otherwise show.
    var bytesWritten: Int {
        lock.lock()
        let target = destination
        lock.unlock()
        guard let target,
              let attrs = try? FileManager.default.attributesOfItem(atPath: target.path)
        else { return 0 }
        return (attrs[.size] as? Int) ?? 0
    }

    // MARK: - Sources

    private func startScreen(plan: CapturePlan) {
        let wantedDisplay = displayID
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                // Same fallback rule as the still-frame capture path: an unplugged monitor
                // must not end the recording, it must move it to a display that is there.
                let display = wantedDisplay.flatMap { id in content.displays.first { $0.displayID == id } }
                    ?? content.displays.first
                guard let display else { throw VideoCaptureError.noDisplay }

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let cfg = SCStreamConfiguration()
                cfg.width = plan.width
                cfg.height = plan.height
                cfg.scalesToFit = true
                cfg.showsCursor = true
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
                // The frame rate is enforced here rather than by dropping frames later:
                // a frame that is never captured costs no encode, no copy and no disk.
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(plan.frameRate))
                // Enough depth to ride out a stall without the system dropping frames on
                // our behalf; not so much that a stall costs hundreds of megabytes of RAM.
                cfg.queueDepth = 5

                let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.screenQueue)
                try await stream.startCapture()
                self.store(stream: stream)
                Self.log.notice("screen capture started on display \(display.displayID, privacy: .public)")
            } catch {
                self.note(failure: VideoCaptureError.streamFailed(error.localizedDescription).localizedDescription)
            }
        }
    }

    private func startCamera(plan: CapturePlan) throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw VideoCaptureError.cameraDenied
        }
        guard let device = CameraCapture.device(id: cameraID) else {
            throw VideoCaptureError.noCamera("none is connected")
        }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) }
        catch { throw VideoCaptureError.noCamera(error.localizedDescription) }

        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw VideoCaptureError.noCamera("\(device.localizedName) is in use by another app")
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        // Scaled by AVFoundation on the way out, so a camera-only recording goes straight
        // into the file untouched and a composited one is shrinking a small picture rather
        // than a 4K one. The size comes from the device's own aspect ratio — forcing 16:9
        // onto a 4:3 camera would stretch every face in the recording.
        let size = CameraCapture.outputSize(for: plan, device: device)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
        ]
        // A late frame is worth less than a current one, and the encoder is what decides
        // the pace — so never let frames queue up behind it.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: cameraQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw VideoCaptureError.noCamera("its frames cannot be read")
        }
        session.addOutput(output)
        session.commitConfiguration()

        lock.lock(); self.session = session; lock.unlock()
        // `startRunning` blocks for as long as the camera takes to warm up — a second or
        // more for a Continuity Camera — so it never happens on the main thread.
        cameraQueue.async { session.startRunning() }
        Self.log.notice("camera capture started on \(device.localizedName, privacy: .public)")
    }

    /// Takes the lock on the caller's behalf, from a synchronous context.
    ///
    /// `NSLock.lock()` is unavailable inside an `async` function — it blocks a thread the
    /// concurrency runtime may want back — so the one place that needs it from a Task
    /// hops through here instead.
    private func store(stream: SCStream) {
        lock.lock()
        self.stream = stream
        lock.unlock()
    }

    private func stopSources() {
        lock.lock()
        let stream = self.stream
        let session = self.session
        self.stream = nil
        self.session = nil
        lock.unlock()

        if let session, session.isRunning { session.stopRunning() }
        guard let stream else { return }
        let done = DispatchSemaphore(value: 0)
        stream.stopCapture { _ in done.signal() }
        // Two seconds is far longer than a stop takes; the timeout exists so a wedged
        // stream cannot wedge the app on the way out.
        _ = done.wait(timeout: .now() + 2)
    }

    private func clear() {
        lock.lock()
        writer = nil; videoInput = nil; audioInput = nil; adaptor = nil
        destination = nil; latestCamera = nil; lastFrameTime = nil
        lock.unlock()
    }

    private func note(failure: String) {
        lock.lock()
        let first = self.failed == nil
        if first { self.failed = failure }
        lock.unlock()
        guard first else { return }
        Self.log.error("\(failure, privacy: .public)")
        DispatchQueue.main.async { [weak self] in self?.onFailure?(failure) }
    }

    // MARK: - Frames

    /// One frame into the file, at the time it actually happened.
    ///
    /// Not private, and deliberately: `Scripts/verify-video.sh` pushes synthetic frames
    /// through here to prove the muxer produces a playable movie with both tracks in it.
    /// There is no way to do that from a real capture in a test — a bare binary gets no
    /// Screen Recording grant from TCC — and "the encoder settings are probably fine" is
    /// not something to find out from a user.
    func append(base: CVPixelBuffer, overlay: CVPixelBuffer?, at time: CMTime) {
        lock.lock()
        guard let adaptor, let input = videoInput, let writer, writer.status == .writing else {
            lock.unlock(); return
        }
        let start = sessionStart
        let interval = plan.frameRate > 0 ? 1.0 / Double(plan.frameRate) : 0
        let last = lastFrameTime
        lock.unlock()

        // Never before the session started — a buffer captured microseconds before
        // `startSession` would be rejected outright and take the whole track with it.
        let pts = CMTimeCompare(time, start) < 0 ? start : time

        // The camera can free-run faster than the plan asks for. Ten percent of slack, so
        // ordinary jitter does not throw away every other frame.
        if let last, interval > 0, CMTimeGetSeconds(CMTimeSubtract(pts, last)) < interval * 0.9 { return }

        guard input.isReadyForMoreMediaData else {
            lock.lock(); framesDropped += 1; lock.unlock()
            return
        }

        let buffer: CVPixelBuffer
        if let overlay {
            guard let composed = composite(base: base, overlay: overlay, adaptor: adaptor) else {
                lock.lock(); framesDropped += 1; lock.unlock()
                return
            }
            buffer = composed
        } else {
            buffer = base
        }

        if adaptor.append(buffer, withPresentationTime: pts) {
            lock.lock(); framesWritten += 1; lastFrameTime = pts; lock.unlock()
        } else {
            lock.lock(); framesDropped += 1; lock.unlock()
            // `writer` is the copy taken under the lock above, not a fresh read — this
            // runs on a capture queue while the main actor may be tearing the writer down.
            if let why = writer.error?.localizedDescription {
                note(failure: VideoCaptureError.writerRefused(why).localizedDescription)
            }
        }
    }

    /// Screen with the camera in the corner.
    ///
    /// Bottom-right, a fifth of the width, with a margin proportional to the frame — the
    /// same place every other tool puts it, which matters more than being clever, because
    /// it is the corner people already know to ignore. Deliberately square-cornered: a
    /// rounded mask is another Core Image pass on every single frame, for a decoration.
    private func composite(base: CVPixelBuffer,
                           overlay: CVPixelBuffer,
                           adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let out else { return nil }

        let width = CGFloat(CVPixelBufferGetWidth(out))
        let height = CGFloat(CVPixelBufferGetHeight(out))
        let inset = width * Self.insetWidthFraction
        let margin = width * Self.insetMarginFraction

        let camera = CIImage(cvPixelBuffer: overlay)
        let scale = inset / max(1, camera.extent.width)
        let placed = camera
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: width - inset - margin, y: margin))

        let frame = placed.composited(over: CIImage(cvPixelBuffer: base))
        ci.render(frame,
                  to: out,
                  bounds: CGRect(x: 0, y: 0, width: width, height: height),
                  colorSpace: CGColorSpaceCreateDeviceRGB())
        return out
    }

    /// How wide the camera inset is, as a fraction of the frame. A fifth is big enough to
    /// read a face on a laptop screen and small enough not to cover the thing being
    /// demonstrated.
    static let insetWidthFraction: CGFloat = 0.20
    static let insetMarginFraction: CGFloat = 0.02

    // MARK: - Audio

    /// Lays the finished mixdown down as the movie's audio track.
    ///
    /// Chunked rather than handed over as one enormous sample buffer: an hour of audio is
    /// 173 MB, and a single buffer that size is both a memory spike and something the
    /// encoder has to be given permission to work through in pieces anyway.
    private func writeAudioTrack(samples: [Int16],
                                 sampleRate: Int,
                                 into input: AVAssetWriterInput,
                                 from start: CMTime) throws {
        guard !samples.isEmpty else { input.markAsFinished(); return }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)

        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                             asbd: &asbd,
                                             layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &format) == noErr,
              let format else {
            throw VideoCaptureError.writerRefused("the audio format could not be described")
        }

        let perChunk = sampleRate / 2                     // half a second
        let chunks = stride(from: 0, to: samples.count, by: perChunk).map { offset in
            Array(samples[offset..<min(offset + perChunk, samples.count)])
        }

        var index = 0
        var failure: String?
        let done = DispatchSemaphore(value: 0)
        // Pull-based: the encoder says when it can take more. Pushing regardless is how
        // an audio track ends up truncated on a slow disk.
        input.requestMediaDataWhenReady(on: audioQueue) {
            while input.isReadyForMoreMediaData {
                guard index < chunks.count else {
                    input.markAsFinished()
                    done.signal()
                    return
                }
                let offset = index * perChunk
                let pts = CMTimeAdd(start, CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(sampleRate)))
                guard let sample = Self.sampleBuffer(chunks[index], format: format, at: pts, rate: sampleRate) else {
                    failure = "an audio buffer could not be built"
                    input.markAsFinished()
                    done.signal()
                    return
                }
                if !input.append(sample) {
                    failure = "the audio track could not be written"
                    input.markAsFinished()
                    done.signal()
                    return
                }
                index += 1
            }
        }

        if done.wait(timeout: .now() + 30) == .timedOut {
            throw VideoCaptureError.writerRefused("the audio track did not finish within 30 seconds")
        }
        if let failure { throw VideoCaptureError.writerRefused(failure) }
    }

    private static func sampleBuffer(_ samples: [Int16],
                                     format: CMAudioFormatDescription,
                                     at pts: CMTime,
                                     rate: Int) -> CMSampleBuffer? {
        let byteCount = samples.count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil,
                                                 blockLength: byteCount,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0,
                                                 dataLength: byteCount,
                                                 flags: 0,
                                                 blockBufferOut: &block) == noErr,
              let block else { return nil }

        let copied = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base,
                                                 blockBuffer: block,
                                                 offsetIntoDestination: 0,
                                                 dataLength: byteCount)
        }
        guard copied == noErr else { return nil }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sizes = [MemoryLayout<Int16>.size]
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                        dataBuffer: block,
                                        formatDescription: format,
                                        sampleCount: samples.count,
                                        sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1,
                                        sampleSizeArray: &sizes,
                                        sampleBufferOut: &out) == noErr else { return nil }
        return out
    }

    // MARK: - Encoder settings

    /// Why each key is here:
    ///
    ///  * `AVVideoAverageBitRateKey` is the whole storage story — see `CapturePlan`.
    ///  * `AVVideoExpectedSourceFrameRateKey` lets the encoder budget across a second
    ///    instead of guessing from the first few frames, which matters a great deal when
    ///    idle frames are being dropped and the real rate is bursty.
    ///  * `AVVideoMaxKeyFrameIntervalKey` at two seconds keeps seeking usable. Longer
    ///    saves space and makes scrubbing feel broken.
    ///  * `AVVideoAllowFrameReorderingKey: false` means no B-frames: slightly bigger, and
    ///    it removes an entire class of timestamp problem in a stream whose frames arrive
    ///    irregularly because idle ones were never sent.
    static func videoSettings(for plan: CapturePlan) -> [String: Any] {
        [
            AVVideoCodecKey: plan.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: plan.videoBitRate,
                AVVideoExpectedSourceFrameRateKey: plan.frameRate,
                AVVideoMaxKeyFrameIntervalKey: plan.frameRate * 2,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ]
    }

    /// AAC at 64 kbps mono. The source is a 24 kHz mono mixdown of two voices, so there
    /// is nothing above 12 kHz to preserve and stereo would be two copies of one signal —
    /// this is transparent for speech at a sixth of the WAV's size. The uncompressed
    /// original is still exactly what audio-only mode writes.
    static func audioSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: SessionRecorder.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: CaptureStorage.movieAudioBytesPerSecond * 8,
        ]
    }
}

// MARK: - ScreenCaptureKit

extension VideoTrackWriter: SCStreamOutput, SCStreamDelegate {

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }

        // SCK reports every frame it considered, including ones where nothing changed.
        // Encoding those would be paying full price to say "still the same", so only
        // complete frames — ones with new pixels in them — are written.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let base = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        lock.lock()
        let wantsCamera = plan.mode.capturesCamera
        let camera = latestCamera
        lock.unlock()

        append(base: base,
               overlay: wantsCamera ? camera : nil,
               at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        note(failure: VideoCaptureError.streamFailed(error.localizedDescription).localizedDescription)
    }
}

// MARK: - Camera

extension VideoTrackWriter: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lock.lock()
        let compositing = plan.mode.capturesScreen
        latestCamera = buffer
        lock.unlock()

        // In `.full` the screen drives the timeline and this frame is only ever the
        // corner of somebody else's — so it is latched above and nothing else happens
        // here. Camera-only is the reverse: these frames are the recording.
        guard !compositing else { return }
        append(base: buffer, overlay: nil, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
