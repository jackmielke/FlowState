import Foundation
import AppKit
import FlowStateCore

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

    /// Prints exactly what the model is told about the tools, and quits.
    ///
    /// The schema is assembled from three places and sent once, invisibly, when a session
    /// opens — so "why did it pick that value" is otherwise unanswerable without a packet
    /// capture. `FLOWSTATE_DUMP_TOOLS=1`.
    static func dumpToolsIfRequested(state: AppState) {
        guard ProcessInfo.processInfo.environment["FLOWSTATE_DUMP_TOOLS"] == "1" else { return }
        // stderr, unbuffered, like every other diagnostic here — `print` to a redirected
        // stdout is fully buffered and the `exit` below can beat the flush.
        var out = ""
        // The tools the SESSION is given, not just the native registry. Dev Mode's
        // dispatcher is added inside `sendSessionUpdate`, so a dump of the registry
        // alone shows no way to reach Claude Code and looks like the feature is
        // missing when it is present.
        let session = RealtimeClient.sessionTools(state.settings,
                                                  nativeTools: state.tools.realtimeTools())
        for tool in session {
            guard let name = tool["name"] as? String else { continue }
            out += "── \(name)\n"
            out += (tool["description"] as? String ?? "").split(separator: "\n")
                    .map { "   \($0)" }.joined(separator: "\n") + "\n"
            if let params = tool["parameters"] as? [String: Any],
               let props = params["properties"] as? [String: [String: Any]] {
                for (key, schema) in props.sorted(by: { $0.key < $1.key }) {
                    let allowed = (schema["enum"] as? [String]).map { " = \($0.joined(separator: " | "))" } ?? ""
                    out += "   • \(key)\(allowed)\n"
                }
            }
            out += "\n"
        }
        FileHandle.standardError.write(Data(out.utf8))
        exit(0)
    }

    static func runIfRequested(state: AppState) async {
        guard let seconds else { return }

        // No session by default: recording opens the microphone itself now, and a smoke
        // test that billed a realtime session every run would not get run.
        // FLOWSTATE_RECORD_TEST_CONNECT=1 exercises the with-assistant path.
        if ProcessInfo.processInfo.environment["FLOWSTATE_RECORD_TEST_CONNECT"] == "1" {
            say("connecting…")
            await state.connect()
            for _ in 0..<60 where !state.audio.running {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard state.audio.running else { say("FAILED — audio engine never started"); exit(1) }
        }

        let started = state.startRecording(mode: mode)
        say("start (\(mode.rawValue)): \(started)")
        guard state.isRecording else { say("FAILED — not recording"); exit(1) }

        // FLOWSTATE_RECORD_TEST_PAUSE=<seconds> holds the take halfway through.
        //
        // The only way to check the video half of a pause. A unit test can prove the
        // recorder drops what it is fed — `verify-recorder.sh` does — but not that
        // `VideoTrackWriter` shifts its timestamps by the same span, because that needs a
        // real ScreenCaptureKit stream and a real host clock. The number to look at is
        // the last line: the file should be as long as the time spent RECORDING, not as
        // long as the wall clock, and a movie whose length includes the pause is a movie
        // whose pictures have drifted away from its audio.
        let held = Double(ProcessInfo.processInfo.environment["FLOWSTATE_RECORD_TEST_PAUSE"] ?? "") ?? 0
        if held > 0 {
            try? await Task.sleep(for: .seconds(seconds / 2))
            say("pause: \(state.runVoiceCommand(.pauseRecording, from: .ui))")
            try? await Task.sleep(for: .seconds(min(held, 30)))
            say("resume: \(state.runVoiceCommand(.resumeRecording, from: .ui))")
            try? await Task.sleep(for: .seconds(seconds / 2))
        } else {
            try? await Task.sleep(for: .seconds(seconds))
        }

        let stopped = state.finishRecording(reason: "smoke test")
        say("stop: \(stopped)")
        if let r = state.lastRecording {
            say("file: \(r.url.lastPathComponent) — \(r.bytes) bytes, \(String(format: "%.2f", r.seconds))s")
            if held > 0 {
                say(String(format: "paused %.0fs — the file should be ~%.0fs, not ~%.0fs",
                           held, seconds, seconds + held))
            }
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
