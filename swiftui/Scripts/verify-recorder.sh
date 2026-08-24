#!/usr/bin/env bash
# Proves SessionRecorder actually records — against the real source file, not a copy.
#
#   ./Scripts/verify-recorder.sh
#
# WHY THIS EXISTS
# The recorder lives in the app target, which cannot be unit-tested: it is compiled
# alongside AppKit, AVAudioEngine and ScreenCaptureKit, none of which come up in a test
# runner. So the bug it shipped with — the microphone was never teed into it, and every
# recording came out as zero seconds and was then discarded as "too short" — was
# invisible to `swift test` and stayed that way.
#
# `SessionRecorder.swift` imports nothing but Foundation, AVFoundation, Combine, os and
# VibeVoiceCore — and VibeVoiceCore is itself pure Foundation. That is deliberate, and it
# is what lets this build the two of them on their own, without AppKit or a window server,
# and exercise the recorder directly from the background threads the audio tap runs on.
#
# If this script stops compiling because SessionRecorder has acquired an import of
# ScreenCaptureKit, AppKit or AVCaptureSession, that is the point of it: the video half of
# a recording belongs behind `RecordingVideoTrack`, in VideoCapture.swift, where it cannot
# take the audio path down with it.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Sources/VibeVoice/SessionRecorder.swift"
WORK="$(mktemp -d)"
OUT="$WORK/verify-recorder"
# Top-level code is only legal in a file called main.swift.
DRIVER="$WORK/main.swift"

cat > "$DRIVER" <<'SWIFT'
import Foundation
import VibeVoiceCore

var failures = 0
func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    print("\(ok ? "  ok  " : "  FAIL") \(what)\(detail.isEmpty ? "" : " — \(detail)")")
    if !ok { failures += 1 }
}

let rate = SessionRecorder.sampleRate

/// One chunk of PCM16, the size AudioEngine actually hands over (~20 ms at 24 kHz).
func chunk(_ frames: Int, amplitude: Int16 = 8_000, phase: Int = 0) -> Data {
    var out = Data(capacity: frames * 2)
    for i in 0..<frames {
        let t = Double(phase + i) / Double(rate)
        let v = Int16(Double(amplitude) * sin(2 * .pi * 440 * t))
        withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
    }
    return out
}

func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url) }

// ---------------------------------------------------------------- 1. the happy path
print("\n1. a second of microphone audio comes back as a second of WAV")
do {
    let recorder = SessionRecorder()
    guard recorder.start(title: "verify-recorder happy path") != nil else {
        print("  FAIL could not start"); exit(1)
    }
    // 50 chunks of 480 frames = 24 000 frames = exactly one second. The mic is the
    // clock, so this alone fixes the length of the file.
    for i in 0..<50 { recorder.appendMic(chunk(480, phase: i * 480)) }

    switch recorder.stop() {
    case .saved(let url, let seconds):
        check(abs(seconds - 1.0) < 0.001, "one second captured", String(format: "%.3fs", seconds))
        // Audio-only must still be a WAV, in the same folder, named the same way. This is
        // the promise to everyone who was using the app before video existed.
        check(url.pathExtension == "wav", "still a WAV", url.lastPathComponent)
        check(url.deletingLastPathComponent() == SessionRecorder.directoryURL,
              "still in the recordings folder", url.deletingLastPathComponent().path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        check(size == 44 + 24_000 * 2, "WAV is header + samples", "\(size) bytes")
        // Header sanity: anything that cannot be read back is not a recording.
        let data = try! Data(contentsOf: url)
        check(data.prefix(4) == Data("RIFF".utf8), "RIFF magic")
        check(data[8..<12] == Data("WAVE".utf8), "WAVE magic")
        cleanup(url)
    case let other:
        check(false, "saved a file", "got \(other)")
    }
}

// -------------------------------------------------------------- 1b. the two streams mix
print("\n1b. the model's voice lands on the mic's timeline")
do {
    let recorder = SessionRecorder()
    _ = recorder.start(title: "verify-recorder mixdown")
    for i in 0..<50 { recorder.appendMic(chunk(480, phase: i * 480)) }
    // Mid-conversation: the model speaks while the mic keeps running. This must be mixed
    // into the second already captured, not appended after it.
    recorder.appendAssistant(chunk(4_800, amplitude: 4_000))
    for i in 50..<100 { recorder.appendMic(chunk(480, phase: i * 480)) }

    switch recorder.stop() {
    case .saved(let url, let seconds):
        check(abs(seconds - 2.0) < 0.001, "two seconds of mic, not three",
              String(format: "%.3fs", seconds))
        cleanup(url)
    case let other:
        check(false, "saved a file", "got \(other)")
    }
}

// The one case where the assistant legitimately makes the file longer: it is still
// talking when the mic stops, i.e. the tail of a reply the user let run.
print("\n1c. a reply still running at the end is not truncated")
do {
    let recorder = SessionRecorder()
    _ = recorder.start(title: "verify-recorder tail")
    for i in 0..<50 { recorder.appendMic(chunk(480, phase: i * 480)) }
    recorder.appendAssistant(chunk(12_000, amplitude: 4_000))   // 0.5s past the mic
    switch recorder.stop() {
    case .saved(let url, let seconds):
        check(abs(seconds - 1.5) < 0.001, "the tail is kept", String(format: "%.3fs", seconds))
        cleanup(url)
    case let other:
        check(false, "saved a file", "got \(other)")
    }
}

// ------------------------------------------------- 2. the bug this file exists to catch
print("\n2. a recording nothing was ever fed into is reported, not silently dropped")
do {
    let recorder = SessionRecorder()
    _ = recorder.start(title: "verify-recorder starved")
    // Exactly the old failure: the button went red, the tap was never wired up. It has
    // to sit there a while, because that is what makes it a fault rather than a fumble.
    Thread.sleep(forTimeInterval: 1.1)
    switch recorder.stop() {
    case .captureNeverStarted(let elapsed):
        check(elapsed >= 1, "reported as captureNeverStarted", String(format: "%.1fs red", elapsed))
    case let other:
        check(false, "reported as captureNeverStarted", "got \(other)")
    }
    check(recorder.lastError != nil, "and says so in lastError", recorder.lastError ?? "nil")
}

print("\n2b. but double-clicking the button is not dressed up as a fault")
do {
    let recorder = SessionRecorder()
    _ = recorder.start(title: "verify-recorder fumble")
    switch recorder.stop() {
    case .captureNeverStarted(let elapsed):
        check(elapsed < 1, "still captureNeverStarted", String(format: "%.2fs", elapsed))
    case let other:
        check(false, "still captureNeverStarted", "got \(other)")
    }
    check(recorder.lastError == nil, "and raises no error", recorder.lastError ?? "nil")
}

// ------------------------------------------------------------------- 3. genuinely short
print("\n3. a real but tiny recording is 'too short', which is a different thing")
do {
    let recorder = SessionRecorder()
    _ = recorder.start(title: "verify-recorder short")
    recorder.appendMic(chunk(480))          // 20 ms, under the 250 ms floor
    switch recorder.stop() {
    case .tooShort(let seconds):
        check(seconds > 0, "reported as tooShort", String(format: "%.3fs", seconds))
    case let other:
        check(false, "reported as tooShort", "got \(other)")
    }
    check(recorder.lastError == nil, "and is not treated as an error")
}

// ------------------------------------------------------------------------ 4. threading
print("\n4. the audio thread can feed it while the main thread stops it")
do {
    let recorder = SessionRecorder()
    _ = recorder.start(title: "verify-recorder threads")
    let group = DispatchGroup()
    // Four concurrent producers, because the tap is a real-time thread and the mixer
    // buffer is shared mutable state. Without the lock this is a crash, not a warning.
    for _ in 0..<4 {
        DispatchQueue.global().async(group: group) {
            for i in 0..<300 { recorder.appendMic(chunk(480, phase: i * 480)) }
        }
    }
    group.wait()
    switch recorder.stop() {
    case .saved(let url, let seconds):
        check(seconds > 5, "survived 1200 concurrent chunks", String(format: "%.2fs", seconds))
        cleanup(url)
    case let other:
        check(false, "survived 1200 concurrent chunks", "got \(other)")
    }
    // Feeding a stopped recorder must be a no-op rather than a crash: buffers already
    // in flight on the audio thread arrive after the user has hit stop.
    recorder.appendMic(chunk(480))
    recorder.appendAssistant(chunk(480))
    check(true, "late buffers after stop are ignored")
}

// ----------------------------------------------------------------------- 5. the mixer
print("\n5. two loud voices at once clip instead of wrapping to the opposite sign")
do {
    let recorder = SessionRecorder()
    _ = recorder.start(title: "verify-recorder clipping")
    let loud = chunk(24_000, amplitude: 30_000)
    recorder.appendMic(loud)
    // Mixed in at the same point on the timeline: 30 000 + 30 000 overflows Int16.
    recorder.appendAssistant(loud)
    guard case .saved(let url, _) = recorder.stop() else {
        check(false, "saved"); exit(failures == 0 ? 0 : 1)
    }
    let data = try! Data(contentsOf: url)
    var wrapped = 0
    data.withUnsafeBytes { raw in
        let s = raw.bindMemory(to: Int16.self)
        // Skip the 22-Int16 header. A wrap shows up as a large negative sample where the
        // sine was positive — the loud click this saturation exists to prevent.
        for i in 22..<s.count where s[i] < -32_000 { wrapped += 1 }
    }
    check(wrapped == 0, "no wrapped samples", "\(wrapped) found")
    cleanup(url)
}

// -------------------------------------------------------------- 6. the video contract
//
// No ScreenCaptureKit here on purpose. What is being checked is the wiring the video
// modes depend on and that the audio path cannot see: that a video plan writes a .mov,
// that the writer is handed the FINISHED mixdown rather than a running one, and — the
// one that matters most — that every way of ending a recording that is not a saved file
// still tears the capture down. A camera light left on after stop is the worst possible
// bug in this feature.
print("\n6. a video recording hands the finished mixdown to the writer, exactly once")

final class FakeVideoTrack: RecordingVideoTrack, @unchecked Sendable {
    var began: (url: URL, plan: CapturePlan)?
    var finishedWith: [Int16]?
    var cancelled = 0
    var failBegin = false
    var bytesWritten = 0
    /// Every pause and resume it was told about, in order.
    var pauses: [Bool] = []

    func begin(destination: URL, plan: CapturePlan) throws {
        if failBegin { throw NSError(domain: "test", code: 1) }
        began = (destination, plan)
    }
    func finish(samples: [Int16], sampleRate: Int) throws { finishedWith = samples }
    func setPaused(_ paused: Bool) { pauses.append(paused) }
    func cancel() { cancelled += 1 }
}

let screenPlan = CapturePlan.make(mode: .audioScreen, profile: .balanced, screen: (1_920, 1_080))

do {
    let recorder = SessionRecorder()
    let track = FakeVideoTrack()
    let url = recorder.start(title: "verify-recorder video", plan: screenPlan, video: track)
    check(url?.pathExtension == "mov", "writes a .mov", url?.lastPathComponent ?? "nil")
    check(track.began?.url == url, "the writer is told where the file goes")
    check(track.began?.plan.mode == .audioScreen, "…and what is being captured")

    // Mid-conversation, exactly as in 1b: the model speaks while the mic keeps running.
    for i in 0..<50 { recorder.appendMic(chunk(480, phase: i * 480)) }
    recorder.appendAssistant(chunk(4_800, amplitude: 4_000))
    for i in 50..<100 { recorder.appendMic(chunk(480, phase: i * 480)) }

    switch recorder.stop() {
    case .saved(let saved, let seconds):
        check(saved == url, "saved to the same path")
        check(abs(seconds - 2.0) < 0.001, "two seconds", String(format: "%.3fs", seconds))
        // The whole reason the audio is handed over at the end rather than streamed: the
        // model's voice is mixed in retroactively, so a sample already "written" can still
        // change. 48 000 samples — the assistant mixed INTO the mic's timeline, not
        // appended after it, which is what streaming would have written.
        check(track.finishedWith?.count == 48_000, "the writer got the finished mixdown",
              "\(track.finishedWith?.count ?? -1) samples")
        check(track.cancelled == 0, "and was not cancelled")
        // The fake never created a file, but `start` may have; leave the folder as found.
        cleanup(saved)
    case let other:
        check(false, "saved a movie", "got \(other)")
    }
}

// ------------------------------------------------------------------------ 6a. pausing
//
// A pause is a splice: what is fed while paused is dropped, so the file is shorter by
// exactly the length of the pause rather than containing that much silence. The video
// writer has to be told, because it is stamping frames against a clock the audio just
// stopped sharing — see `VideoTrackWriter.setPaused`.
print("\n6a. a pause takes nothing in, and the file continues where it left off")
do {
    let recorder = SessionRecorder()
    let track = FakeVideoTrack()
    let url = recorder.start(title: "verify-recorder pause", plan: screenPlan, video: track)

    for i in 0..<25 { recorder.appendMic(chunk(480, phase: i * 480)) }      // 0.5s
    check(recorder.setPaused(true) == .paused(at: 0.5), "pauses where the samples stop",
          String(format: "%.2fs", recorder.duration))
    check(track.pauses == [true], "and the video writer is told")

    // Everything below is fed while paused and must land nowhere.
    for i in 0..<50 { recorder.appendMic(chunk(480, phase: i * 480)) }
    recorder.appendAssistant(chunk(4_800, amplitude: 4_000))
    recorder.appendSystemAudio(Array(repeating: 6_000, count: 4_800), at: 0.6)

    check(recorder.setPaused(true) == .unchanged(paused: true), "pausing twice is not an error")
    check(recorder.setPaused(false) == .resumed(at: 0.5), "resumes at the same second")
    check(track.pauses == [true, false], "and the writer is told that too")

    for i in 0..<25 { recorder.appendMic(chunk(480, phase: i * 480)) }      // another 0.5s

    switch recorder.stop() {
    case .saved(let saved, let seconds):
        check(abs(seconds - 1.0) < 0.001, "one second in the file, not two",
              String(format: "%.3fs", seconds))
        check(track.finishedWith?.count == 24_000, "the mixdown skipped the pause",
              "\(track.finishedWith?.count ?? -1) samples")
        cleanup(saved)
    case let other:
        check(false, "saved", "got \(other)")
    }
}

print("\n6a-ii. pausing something that is not recording changes nothing")
do {
    let recorder = SessionRecorder()
    check(recorder.setPaused(true) == .notRecording, "says so")
    check(recorder.isPaused == false, "and does not go paused")
    // And a take started afterwards is not born paused.
    _ = recorder.start(title: "verify-recorder pause-then-start")
    check(recorder.isPaused == false, "a new take starts running")
    recorder.appendMic(chunk(480))
    _ = recorder.stop()
}

print("\n6b. a video plan with no writer refuses to start rather than recording nothing")
do {
    let recorder = SessionRecorder()
    check(recorder.start(title: "verify-recorder no writer", plan: screenPlan, video: nil) == nil,
          "start returns nil")
    check(recorder.isRecording == false, "and the button does not go red")
}

print("\n6c. a writer that cannot open its file does not leave a recording running")
do {
    let recorder = SessionRecorder()
    let track = FakeVideoTrack()
    track.failBegin = true
    check(recorder.start(title: "verify-recorder bad writer", plan: screenPlan, video: track) == nil,
          "start returns nil")
    check(recorder.lastError != nil, "and says why", recorder.lastError ?? "nil")
}

print("\n6d. every ending that is not a saved file tears the capture down")
do {
    // Too short. The file must not be left behind either — a zero-byte .mov in the
    // recordings folder is something the user will find later and try to play.
    let recorder = SessionRecorder()
    let track = FakeVideoTrack()
    let url = recorder.start(title: "verify-recorder short video", plan: screenPlan, video: track)
    recorder.appendMic(chunk(480))
    switch recorder.stop() {
    case .tooShort:
        check(track.cancelled == 1, "cancelled once", "\(track.cancelled)")
        check(track.finishedWith == nil, "and never asked to finish")
        check(!FileManager.default.fileExists(atPath: url?.path ?? ""), "no file left behind")
    case let other:
        check(false, "reported as tooShort", "got \(other)")
    }
}
do {
    // Nothing ever fed. Same requirement, different door.
    let recorder = SessionRecorder()
    let track = FakeVideoTrack()
    _ = recorder.start(title: "verify-recorder starved video", plan: screenPlan, video: track)
    Thread.sleep(forTimeInterval: 1.1)
    switch recorder.stop() {
    case .captureNeverStarted:
        check(track.cancelled == 1, "cancelled once", "\(track.cancelled)")
    case let other:
        check(false, "reported as captureNeverStarted", "got \(other)")
    }
}

print("")
if failures == 0 {
    print("PASS — the recorder records, reports every failure by name, is thread-safe,\n       and hands a video recording its audio exactly once.")
} else {
    print("FAIL — \(failures) check\(failures == 1 ? "" : "s") did not hold.")
}
exit(failures == 0 ? 0 : 1)
SWIFT

# VibeVoiceCore first, as a real module, because SessionRecorder imports it for
# `RecordingName` and `CapturePlan` — the naming and sizing rules, which are shared with
# the video writer and are unit-tested on the other side of the package.
echo "==> building VibeVoiceCore (pure Foundation)"
swiftc -swift-version 5 -O -emit-module -emit-library -static \
  -module-name VibeVoiceCore \
  -emit-module-path "$WORK/VibeVoiceCore.swiftmodule" \
  -o "$WORK/libVibeVoiceCore.a" \
  Sources/VibeVoiceCore/*.swift

echo "==> compiling $SRC on its own"
swiftc -swift-version 5 -O -I "$WORK" -L "$WORK" -lVibeVoiceCore "$SRC" "$DRIVER" -o "$OUT"
"$OUT"
