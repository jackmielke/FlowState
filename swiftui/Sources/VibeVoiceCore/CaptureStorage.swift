import Foundation

/// How much disk a recording is about to eat, and when to say so out loud.
///
/// Audio-only never needed this: a WAV of a conversation is 48 kB a second, so an hour is
/// 170 MB and nobody has ever been surprised by one. Video is between four and thirty
/// times that, and the surprise is the problem — the failure mode of a screen recorder is
/// not a bad file, it is a full startup disk two hours into a session, which takes the
/// rest of the machine down with it.
///
/// So the size is stated *before* the button is pressed, in the units Finder uses, and
/// again while recording once it stops being trivial. The numbers below are estimates and
/// are always labelled as such: the encoder is variable-bitrate, so a static screen comes
/// in well under and a full-screen video call well over.
public enum CaptureStorage {

    // MARK: - Rates

    /// What `SessionRecorder` actually writes: 24 kHz, 16-bit, mono, uncompressed.
    /// Not a guess — it is `sampleRate × 2` and the WAV has a 44-byte header on top.
    public static let wavBytesPerSecond = 48_000

    /// Audio inside a movie, as AAC at 64 kbps mono. A sixth of the WAV rate, which is
    /// why the audio track is a rounding error next to any video track and is folded in
    /// rather than being worth its own control.
    public static let movieAudioBytesPerSecond = 8_000

    /// Bytes per second of finished file for this plan.
    public static func bytesPerSecond(for plan: CapturePlan) -> Int {
        guard plan.mode.isVideo else { return wavBytesPerSecond }
        return plan.videoBitRate / 8 + movieAudioBytesPerSecond
    }

    public static func bytes(for plan: CapturePlan, seconds: TimeInterval) -> Int {
        guard seconds > 0 else { return 0 }
        return Int(Double(bytesPerSecond(for: plan)) * seconds)
    }

    /// `≈26 MB a minute · 1.6 GB an hour` — both, because a minute is the unit people
    /// think in and an hour is the unit that fills a disk.
    public static func rateLabel(for plan: CapturePlan) -> String {
        let rate = bytesPerSecond(for: plan)
        return "≈" + RecordingFile.size(rate * 60) + " a minute · "
             + RecordingFile.size(rate * 3600) + " an hour"
    }

    /// How long this plan could run before the disk is full, in seconds. Nil when free
    /// space is unknown.
    public static func secondsRemaining(for plan: CapturePlan, freeBytes: Int) -> TimeInterval? {
        guard freeBytes > 0 else { return nil }
        let rate = bytesPerSecond(for: plan)
        guard rate > 0 else { return nil }
        return TimeInterval(freeBytes) / TimeInterval(rate)
    }

    // MARK: - Thresholds
    //
    // Named, so the reason for each number is written down next to it rather than
    // rediscovered from a comparison buried in a branch.

    /// Below this much free space macOS itself starts misbehaving — Spotlight stalls,
    /// swap fails, apps are killed. Recording video into it is not a thing to warn about
    /// politely.
    public static let criticalFreeBytes = 2_000_000_000

    /// An hour that writes more than this is "large" whatever the disk looks like.
    ///
    /// The number is chosen against what the profiles actually produce rather than picked
    /// round: an hour is ≈0.3 GB on Small, ≈1.6 GB on Balanced, and ≈1.7–1.9 GB on Light
    /// or with the camera composited in. 1.7 GB therefore draws the line where it means
    /// something — the heavy end of the range warns, the default does not. A threshold
    /// the default trips is a threshold people learn to scroll past.
    public static let largeHourBytes = 1_700_000_000

    /// Room for less than this, before starting, is a refusal-shaped fact rather than a
    /// warning — there is not enough space here to record anything worth having.
    ///
    /// Expressed as time rather than as a fraction of the disk because time is what the
    /// user is deciding about ("can I record this meeting?"), and because it keeps
    /// working if a future profile writes five times what today's do.
    public static let criticalPlanSeconds: TimeInterval = 15 * 60

    /// And room for less than an afternoon is worth mentioning before a long session.
    /// Four hours of Balanced is about 6 GB, which is the point where a laptop that is
    /// "a bit full" becomes a laptop that stops mid-recording.
    public static let cautionPlanSeconds: TimeInterval = 4 * 3_600

    /// Under five minutes of headroom left, mid-recording, is an emergency: it is less
    /// time than it takes to notice a banner and go delete something.
    public static let criticalRemainingSeconds: TimeInterval = 5 * 60
    /// Under two hours left is worth a heads-up while there is still time to act. It
    /// reads as generous and it is not: two hours of Balanced is a little over 3 GB, so
    /// this is the first threshold above the 2 GB floor that a real disk can actually be
    /// sitting at. A tighter one would be unreachable — the floor would always fire first.
    public static let cautionRemainingSeconds: TimeInterval = 2 * 3_600

    /// A file this big is worth mentioning on its own, even on a disk with room.
    public static let largeFileBytes = 1_000_000_000

    // MARK: - Advice

    /// What to say before the button is pressed.
    ///
    /// - Parameter freeBytes: free space on the volume the recordings folder is on, or 0
    ///   when it could not be read. An unknown disk is not treated as an empty one — the
    ///   advice falls back to talking about the file rather than the volume, because
    ///   inventing a warning about space we could not measure is how a warning stops
    ///   being believed.
    public static func advice(for plan: CapturePlan, freeBytes: Int) -> StorageAdvice {
        let rate = bytesPerSecond(for: plan)
        let hour = rate * 3600
        let rateText = rateLabel(for: plan)

        guard plan.mode.isVideo else {
            // Audio has one failure mode worth reporting, and it is the disk being
            // already full rather than the recording filling it.
            if freeBytes > 0 && freeBytes < criticalFreeBytes {
                return StorageAdvice(level: .critical,
                                     headline: "Disk almost full",
                                     detail: "Only \(RecordingFile.size(freeBytes)) free. "
                                           + "Audio is small — \(rateText) — but there may not be room for it.")
            }
            return StorageAdvice(level: .ok, headline: rateText, detail: rateText + ".")
        }

        if freeBytes > 0 && freeBytes < criticalFreeBytes {
            return StorageAdvice(level: .critical,
                                 headline: "Disk almost full",
                                 detail: "Only \(RecordingFile.size(freeBytes)) free, and this writes \(rateText). "
                                       + "Free some space, or record audio only.")
        }

        // Everything from here on is stated as *time*, because "room for 12 minutes" is a
        // decision and "3.4 GB free" is a number you then have to do arithmetic on.
        let left = secondsRemaining(for: plan, freeBytes: freeBytes)

        if let left, left < criticalPlanSeconds {
            return StorageAdvice(level: .critical,
                                 headline: "Room for about \(durationLabel(left))",
                                 detail: "This writes \(rateText), and \(RecordingFile.size(freeBytes)) is free. "
                                       + "Try the Small profile, or record audio only.")
        }

        if let left, left < cautionPlanSeconds {
            return StorageAdvice(level: .caution,
                                 headline: "Room for about \(durationLabel(left))",
                                 detail: "\(rateText), against \(RecordingFile.size(freeBytes)) free. "
                                       + "The Small profile is about a fifth of that.")
        }

        if hour >= largeHourBytes {
            return StorageAdvice(level: .caution,
                                 headline: "Large recording",
                                 detail: "\(rateText). The Small profile is about a fifth of that.")
        }

        return StorageAdvice(level: .ok, headline: rateText, detail: rateText + ".")
    }

    /// What to say while it is running.
    ///
    /// - Parameters:
    ///   - bytesWritten: the estimate so far, or the real file size if it is known.
    ///   - freeBytes: free space *now* — already reduced by what has been written.
    public static func liveAdvice(for plan: CapturePlan,
                                  bytesWritten: Int,
                                  freeBytes: Int) -> StorageAdvice {
        let written = RecordingFile.size(max(0, bytesWritten))
        let left = secondsRemaining(for: plan, freeBytes: freeBytes)

        if freeBytes > 0 && (freeBytes < criticalFreeBytes || (left ?? .infinity) < criticalRemainingSeconds) {
            return StorageAdvice(level: .critical,
                                 headline: "Stop soon — disk nearly full",
                                 detail: "\(written) written, \(RecordingFile.size(freeBytes)) free — "
                                       + "about \(durationLabel(left ?? 0)) left at this rate.")
        }

        if let left, left < cautionRemainingSeconds {
            return StorageAdvice(level: .caution,
                                 headline: "About \(durationLabel(left)) of room left",
                                 detail: "\(written) written. \(RecordingFile.size(freeBytes)) free.")
        }

        if bytesWritten >= largeFileBytes {
            return StorageAdvice(level: .caution,
                                 headline: "\(written) so far",
                                 detail: "\(written) written. \(rateLabel(for: plan)).")
        }

        return StorageAdvice(level: .ok, headline: written, detail: "\(written) written so far.")
    }

    /// `12 minutes`, `3.5 hours` — deliberately coarse. This is a projection from an
    /// average bit rate, and a projection quoted to the second reads as a measurement.
    public static func durationLabel(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 90 { return "\(Int(s.rounded())) seconds" }
        if s < 5_400 { return "\(Int((s / 60).rounded())) minutes" }
        let hours = s / 3600
        return hours < 10 ? String(format: "%.1f hours", hours) : "\(Int(hours.rounded())) hours"
    }

    /// Free space on the volume holding `url`, or 0 when macOS declines to say.
    ///
    /// `volumeAvailableCapacityForImportantUsageKey` rather than the plain available
    /// capacity: it is the number that accounts for purgeable space macOS would evict to
    /// make room, which is what the recording would actually get. The plain key
    /// under-reports by tens of gigabytes on a Mac with iCloud Drive turned on, and a
    /// warning that fires on a disk with 80 GB genuinely free is a warning people learn
    /// to ignore.
    public static func freeBytes(at url: URL) -> Int {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return Int(important)
        }
        return values.volumeAvailableCapacity ?? 0
    }
}

/// One thing to say about storage, and how loudly.
public struct StorageAdvice: Equatable, Sendable {

    /// Ordered so a caller can compare rather than switch — `advice.level >= .caution` is
    /// the question every call site actually asks.
    public enum Level: Int, Comparable, Sendable {
        case ok, caution, critical
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public let level: Level
    /// Short enough for a chip beside the record button.
    public let headline: String
    /// The whole sentence, for the Settings pane and for VoiceOver.
    public let detail: String

    public init(level: Level, headline: String, detail: String) {
        self.level = level
        self.headline = headline
        self.detail = detail
    }

    /// Whether this is worth interrupting the user for. `.ok` advice is still shown — it
    /// is the rate line under the picker — but it never gets a warning triangle.
    public var isWarning: Bool { level >= .caution }

    public var symbol: String {
        switch level {
        case .ok:       return "internaldrive"
        case .caution:  return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }
}
