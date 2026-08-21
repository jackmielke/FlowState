import Foundation
import AVFoundation

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
@MainActor
final class SessionRecorder: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?
    /// Seconds captured so far, derived from samples rather than the wall clock, so it
    /// reports what is actually in the file.
    @Published private(set) var duration: TimeInterval = 0

    private var samples: [Int16] = []
    private var cursor = 0          // where the mic has written up to
    private var url: URL?

    static let sampleRate = 24_000

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeVoice/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - Lifecycle

    func start(title: String) -> URL? {
        guard !isRecording else { return url }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        let safe = title
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = safe.isEmpty ? stamp.string(from: Date())
                                : "\(stamp.string(from: Date())) — \(safe.prefix(40))"
        url = Self.directory.appendingPathComponent(name + ".wav")

        samples.removeAll(keepingCapacity: true)
        cursor = 0
        duration = 0
        startedAt = Date()
        isRecording = true
        return url
    }

    /// Finishes and writes the file. Returns nil when nothing was captured — an empty
    /// recording is a file that only disappoints later.
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        startedAt = nil
        defer { samples.removeAll(keepingCapacity: false) }

        guard let url, samples.count > Self.sampleRate / 4 else { return nil }   // < 0.25s
        do {
            try Self.writeWAV(samples: samples, to: url)
            return url
        } catch {
            FileHandle.standardError.write(Data(
                "[recorder] could not write \(url.lastPathComponent): \(error.localizedDescription)\n".utf8))
            return nil
        }
    }

    // MARK: - Feeding

    /// The microphone, which also advances the timeline.
    func appendMic(_ pcm16: Data) {
        guard isRecording else { return }
        let incoming = Self.toSamples(pcm16)
        if samples.count < cursor + incoming.count {
            samples.append(contentsOf: repeatElement(0, count: cursor + incoming.count - samples.count))
        }
        for (i, s) in incoming.enumerated() {
            samples[cursor + i] = Self.mix(samples[cursor + i], s)
        }
        cursor += incoming.count
        duration = Double(samples.count) / Double(Self.sampleRate)
    }

    /// The model's voice, mixed in at the current point on the timeline.
    func appendAssistant(_ pcm16: Data) {
        guard isRecording else { return }
        let incoming = Self.toSamples(pcm16)
        let at = cursor
        if samples.count < at + incoming.count {
            samples.append(contentsOf: repeatElement(0, count: at + incoming.count - samples.count))
        }
        for (i, s) in incoming.enumerated() {
            samples[at + i] = Self.mix(samples[at + i], s)
        }
        duration = Double(samples.count) / Double(Self.sampleRate)
    }

    // MARK: -

    /// Saturating add. Two voices summing past Int16 would wrap to the opposite sign,
    /// which is heard as a loud click exactly when both people talk at once.
    private static func mix(_ a: Int16, _ b: Int16) -> Int16 {
        Int16(clamping: Int32(a) + Int32(b))
    }

    private static func toSamples(_ d: Data) -> [Int16] {
        guard !d.isEmpty else { return [] }
        return d.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self))
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
    static func library() -> [Recording] {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "wav" }
            .compactMap { u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                let bytes = v?.fileSize ?? 0
                // Header is 44 bytes; everything after it is 2 bytes per sample.
                let seconds = Double(max(0, bytes - 44)) / 2.0 / Double(sampleRate)
                return Recording(url: u, createdAt: v?.creationDate ?? .distantPast,
                                 bytes: bytes, seconds: seconds)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
