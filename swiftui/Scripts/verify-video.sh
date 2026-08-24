#!/usr/bin/env bash
# Proves the video path produces a real, playable movie — against the real source files.
#
#   ./Scripts/verify-video.sh
#
# WHY THIS EXISTS
# A screen recording cannot be tested from `swift test`: the app target owns AppKit and
# ScreenCaptureKit, and a bare binary is refused a Screen Recording grant by TCC no matter
# what it asks for. So the *capture* half is untestable here — but the half that actually
# breaks quietly is the other one. Encoder settings, the pixel buffer pool, the hand-built
# PCM sample buffers, the session clock, whether both tracks end up in the container: all
# of that is a pure muxing problem, and all of it can be exercised by pushing synthetic
# frames through `VideoTrackWriter.append` and then asking AVFoundation to read the result
# back.
#
# What it does NOT prove: that ScreenCaptureKit hands us frames, or that the camera opens.
# Those need a real Mac with real permissions and a real session. Everything between the
# frame arriving and the file being playable is covered.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
OUT="$WORK/verify-video"
DRIVER="$WORK/main.swift"

cat > "$DRIVER" <<'SWIFT'
import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import VibeVoiceCore

// Defined in SettingsView.swift in the real app; this build does not include the UI.
let kSystemAppName = "FlowState"

var failures = 0
func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    print("\(ok ? "  ok  " : "  FAIL") \(what)\(detail.isEmpty ? "" : " — \(detail)")")
    if !ok { failures += 1 }
}

/// One frame of flat colour, in the format the writer's pool hands out.
func frame(width: Int, height: Int, level: UInt8) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                        &buffer)
    let pixels = buffer!
    CVPixelBufferLockBaseAddress(pixels, [])
    if let base = CVPixelBufferGetBaseAddress(pixels) {
        memset(base, Int32(level), CVPixelBufferGetBytesPerRow(pixels) * height)
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    return pixels
}

/// Two seconds of a 440 Hz tone at the recorder's own rate, standing in for the mixdown.
func tone(seconds: Double) -> [Int16] {
    let count = Int(Double(SessionRecorder.sampleRate) * seconds)
    return (0..<count).map { i in
        Int16(8_000 * sin(2 * .pi * 440 * Double(i) / Double(SessionRecorder.sampleRate)))
    }
}

let plan = CapturePlan.make(mode: .audioScreen, profile: .balanced, screen: (1_280, 720))
let target = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("verify-video-\(getpid()).mov")

print("\n1. \(plan.summary) at \(plan.videoBitRate / 1000) kbps")

let writer = VideoTrackWriter()
// ScreenCaptureKit will refuse this process — no bundle, no TCC grant — and that is
// expected here. The refusal must not stop the file being written; the frames below
// stand in for the ones it would have delivered.
writer.onFailure = { _ in }

do {
    try writer.begin(destination: target, plan: plan)
    check(true, "the writer opened the file")
} catch {
    check(false, "the writer opened the file", error.localizedDescription)
    exit(1)
}

// 48 frames spaced at the plan's own frame rate: two seconds of video to sit under two
// seconds of audio. Spaced in presentation time rather than wall clock, because the
// writer throttles on the former — a tight loop of "now" would be one frame and 47 drops.
let base = CMClockGetTime(CMClockGetHostTimeClock())
for i in 0..<48 {
    let pts = CMTimeAdd(base, CMTime(value: CMTimeValue(i), timescale: CMTimeScale(plan.frameRate)))
    writer.append(base: frame(width: plan.width, height: plan.height, level: UInt8(40 + i * 3)),
                  overlay: nil, at: pts)
}

do {
    try writer.finish(samples: tone(seconds: 2), sampleRate: SessionRecorder.sampleRate)
    check(true, "and closed it")
} catch {
    check(false, "and closed it", error.localizedDescription)
    exit(1)
}

// ------------------------------------------------------------ 2. read it back
print("\n2. what came out is a movie both tracks made it into")

let size = ((try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? Int) ?? 0
check(size > 10_000, "the file has real content in it", RecordingFile.size(size))

let asset = AVURLAsset(url: target)
let duration = try await asset.load(.duration)
// At LEAST two seconds, not exactly two.
//
// The frames above are stamped from a clock read after `begin` returned, while the
// writer's session started inside it — so the movie also contains however long `begin`
// took, which is a few milliseconds normally and over a second whenever ScreenCaptureKit
// takes its time being refused by TCC. That gap is a property of this harness, not of the
// writer, and asserting on it made this check fail about a third of the time for a reason
// nobody could act on. The mixdown's own length — the two seconds this file exists to
// carry — is checked exactly, on the audio track, below.
check(CMTimeGetSeconds(duration) >= 1.95, "at least two seconds long",
      String(format: "%.2fs", CMTimeGetSeconds(duration)))

let video = try await asset.loadTracks(withMediaType: .video)
let audio = try await asset.loadTracks(withMediaType: .audio)
check(video.count == 1, "one video track", "\(video.count)")
// The whole point of writing one file: the conversation has to be IN the screen
// recording, not next to it.
check(audio.count == 1, "one audio track", "\(audio.count)")

if let track = video.first {
    let natural = try await track.load(.naturalSize)
    check(Int(natural.width) == plan.width && Int(natural.height) == plan.height,
          "at the size the plan asked for", "\(Int(natural.width)) × \(Int(natural.height))")
    // Even dimensions, or the encoder pads and every frame gets a green stripe.
    check(Int(natural.width) % 2 == 0 && Int(natural.height) % 2 == 0, "with even dimensions")
}
if let track = audio.first {
    let range = try await track.load(.timeRange)
    check(abs(CMTimeGetSeconds(range.duration) - 2.0) < 0.1, "carrying the whole mixdown",
          String(format: "%.2fs", CMTimeGetSeconds(range.duration)))
}

// ------------------------------------------------------- 3. the estimate was honest
print("\n3. the size estimate is in the right neighbourhood")
let predicted = CaptureStorage.bytes(for: plan, seconds: 2)
check(size < predicted * 3, "not wildly under-promised",
      "\(RecordingFile.size(size)) actual vs \(RecordingFile.size(predicted)) estimated")

// ------------------------------------------------------- 3b. the composited path runs
//
// `.full` cannot be driven here — `begin` opens the camera, and a bare binary has no
// Camera grant — but the expensive half of it can: the Core Image pass, the pixel buffer
// pool the composite draws into, and the append that follows. Those are what break, and
// they break identically whichever mode asked for them.
print("\n3b. a composited frame goes through Core Image and into the file")
let composited = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("verify-video-pip-\(getpid()).mov")
let pip = VideoTrackWriter()
pip.onFailure = { _ in }
try pip.begin(destination: composited, plan: plan)
let pipBase = CMClockGetTime(CMClockGetHostTimeClock())
for i in 0..<24 {
    let pts = CMTimeAdd(pipBase, CMTime(value: CMTimeValue(i), timescale: CMTimeScale(plan.frameRate)))
    pip.append(base: frame(width: plan.width, height: plan.height, level: 30),
               overlay: frame(width: 640, height: 360, level: UInt8(120 + i * 4)),
               at: pts)
}
try pip.finish(samples: tone(seconds: 1), sampleRate: SessionRecorder.sampleRate)
let pipTracks = try await AVURLAsset(url: composited).loadTracks(withMediaType: .video)
check(pipTracks.count == 1, "the composited movie has its video track")
let pipSize = ((try? FileManager.default.attributesOfItem(atPath: composited.path))?[.size] as? Int) ?? 0
check(pipSize > 5_000, "and real content in it", RecordingFile.size(pipSize))
try? FileManager.default.removeItem(at: composited)

// ------------------------------------------------------------- 4. cancel leaves nothing
print("\n4. a cancelled recording leaves no file behind")
let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("verify-video-cancel-\(getpid()).mov")
let second = VideoTrackWriter()
second.onFailure = { _ in }
try second.begin(destination: scratch, plan: plan)
second.append(base: frame(width: plan.width, height: plan.height, level: 90), overlay: nil,
              at: CMClockGetTime(CMClockGetHostTimeClock()))
second.cancel()
check(!FileManager.default.fileExists(atPath: scratch.path), "nothing left at the path")

try? FileManager.default.removeItem(at: target)

print("")
if failures == 0 {
    print("PASS — the video path writes a playable movie with the conversation in it.")
} else {
    print("FAIL — \(failures) check\(failures == 1 ? "" : "s") did not hold.")
}
exit(failures == 0 ? 0 : 1)
SWIFT

echo "==> building VibeVoiceCore"
swiftc -swift-version 5 -O -emit-module -emit-library -static \
  -module-name VibeVoiceCore \
  -emit-module-path "$WORK/VibeVoiceCore.swiftmodule" \
  -o "$WORK/libVibeVoiceCore.a" \
  Sources/VibeVoiceCore/*.swift

echo "==> compiling the recorder, the camera and the video writer"
swiftc -swift-version 5 -O -I "$WORK" -L "$WORK" -lVibeVoiceCore \
  Sources/VibeVoice/SessionRecorder.swift \
  Sources/VibeVoice/CameraCapture.swift \
  Sources/VibeVoice/VideoCapture.swift \
  Sources/VibeVoice/SystemAudioTap.swift \
  "$DRIVER" -o "$OUT"
"$OUT"
