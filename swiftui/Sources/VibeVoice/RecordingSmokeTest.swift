import Foundation
import AppKit
import VibeVoiceCore

/// Records for a few seconds and reports what actually landed in the file.
///
/// Set `FLOWSTATE_RECORD_TEST=<seconds>` to run it; the app records, stops, prints one
/// line of counts and quits. It exists because the recording path is the one part of
/// this app that cannot be unit-tested and cannot be checked by looking: the mixdown is
/// assembled from three separate streams — the microphone, the model, and now the
/// speakers — and every way it can be wrong produces a file that plays.
///
/// Optionally set `FLOWSTATE_RECORD_TEST_MODE` to `audio`, `screen`, `camera` or `both`.
/// Defaults to `screen`, since that is the mode where speaker capture matters.
@MainActor
enum RecordingSmokeTest {

    static var seconds: Double? {
        guard let raw = ProcessInfo.processInfo.environment["FLOWSTATE_RECORD_TEST"],
              let v = Double(raw), v > 0 else { return nil }
        return min(v, 120)
    }

    private static var mode: CaptureMode {
        switch ProcessInfo.processInfo.environment["FLOWSTATE_RECORD_TEST_MODE"] ?? "screen" {
        case "audio":  return .audioOnly
        case "camera": return .audioCamera
        case "both":   return .full
        default:       return .audioScreen
        }
    }

    static func runIfRequested(state: AppState) async {
        guard let seconds else { return }

        // The recorder is fed from the capture tap, which only exists while the engine
        // is running — so the test has to open a real session. That is the point: a
        // smoke test that bypassed the live path would not be testing the path.
        if !state.audio.running {
            say("connecting…")
            await state.connect()
            for _ in 0..<60 where !state.audio.running {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        guard state.audio.running else { say("FAILED — audio engine never started"); exit(1) }

        let started = state.startRecording(mode: mode)
        say("start (\(mode.rawValue)): \(started)")
        guard state.isRecording else { say("FAILED — not recording"); exit(1) }

        try? await Task.sleep(for: .seconds(seconds))

        let stopped = state.finishRecording(reason: "smoke test")
        say("stop: \(stopped)")
        if let r = state.lastRecording {
            say("file: \(r.url.lastPathComponent) — \(r.bytes) bytes, \(String(format: "%.2f", r.seconds))s")
        } else {
            say("FAILED — no file")
            exit(1)
        }
        exit(0)
    }

    private static func say(_ s: String) {
        FileHandle.standardError.write(Data("[record-test] \(s)\n".utf8))
    }
}
