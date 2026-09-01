import AVFoundation
import Foundation
import FlowStateCore

/// Recording an utterance and turning it into text.
///
/// A separate `AVAudioRecorder` rather than a tap on the shared `AudioEngine`, for two
/// reasons. The first is that dictation has to work while a voice session is live, and
/// that engine's voice-processing unit is the same one whose teardown left orphaned audio
/// units inside coreaudiod and made every app on the Mac crackle — it is not something to
/// attach a second consumer to casually. The second is that Whisper wants a file, and this
/// gives it one without a conversion step.
@MainActor
final class DictationRecorder {

    private var recorder: AVAudioRecorder?
    private(set) var url: URL?

    /// 16 kHz mono. Whisper downsamples to 16k anyway, so recording higher just makes a
    /// bigger upload and a slower round trip — and latency is the whole product here.
    private static let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

    func start() throws {
        stop()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowstate-dictation-\(UUID().uuidString).m4a")
        let r = try AVAudioRecorder(url: path, settings: Self.settings)
        r.record()
        recorder = r
        url = path
    }

    /// Stops and returns the file, or nil if nothing usable was captured.
    ///
    /// The duration floor matters: a key press too quick to contain speech still produces
    /// a valid file, and sending it to Whisper reliably comes back with a hallucinated
    /// "Thank you." or "you" — the noise-floor artefact every Whisper integration
    /// eventually discovers. Cheaper to never ask.
    @discardableResult
    func stop() -> URL? {
        guard let r = recorder else { return nil }
        let duration = r.currentTime
        r.stop()
        recorder = nil
        guard let path = url else { return nil }
        guard duration >= 0.35 else {
            try? FileManager.default.removeItem(at: path)
            url = nil
            return nil
        }
        return path
    }

    func discard() {
        recorder?.stop()
        recorder = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
    }
}

/// The transcription call.
enum WhisperTranscriber {

    /// `whisper-1` because that is what was asked for, and it is the endpoint's stable
    /// model. `gpt-4o-mini-transcribe` is the faster, more accurate option on the same
    /// endpoint with the same multipart shape — swapping this constant is the whole change
    /// if the round trip ever feels slow.
    static let model = "whisper-1"

    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    enum Failure: Error, LocalizedError {
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let body):
                return "Transcription failed (\(code)): \(body)"
            }
        }
    }

    /// Upload the file and return what was said, already tidied.
    static func transcribe(_ fileURL: URL) async throws -> String {
        let apiKey = try KeyStore.load()
        let audio = try Data(contentsOf: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let boundary = "flowstate-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
                    .data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n".data(using: .utf8)!)
        field("model", model)
        // Plain text back rather than JSON: there is nothing in the JSON envelope we use,
        // and this removes a decode step from the latency path.
        field("response_format", "text")
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(code) else {
            throw Failure.http(code, text.prefix(200).description)
        }
        return Dictation.tidy(text)
    }
}
