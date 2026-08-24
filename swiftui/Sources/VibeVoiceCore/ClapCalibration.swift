import Foundation

/// Working out what this person's claps actually look like, and what the dial should be.
///
/// Tuning a wake trigger by describing it does not work — "somewhat loudly" is not a
/// number, and the number depends on the room, the microphone, the distance and the
/// hands. The only reliable way is to clap a few times and measure.
public enum ClapCalibration {

    /// One peak reading.
    public struct Sample: Equatable, Sendable {
        public let at: TimeInterval
        public let peak: Float
        public init(at: TimeInterval, peak: Float) {
            self.at = at
            self.peak = peak
        }
    }

    public struct Result: Equatable, Sendable {
        /// The claps that were found, loudest sample of each.
        public let claps: [Sample]
        /// The room, while not clapping.
        public let room: Float
        /// Where the dial should go, 0...1.
        public let sensitivity: Float
        /// One sentence for the panel.
        public let advice: String
        public var isUsable: Bool { claps.count >= 2 }
    }

    /// Two peaks closer together than this are one clap, seen twice.
    static let separation: TimeInterval = 0.09

    /// Picks the peaks out of a recording of somebody clapping.
    ///
    /// Local maxima rather than "everything above a threshold", because the threshold is
    /// the unknown here — that is the entire point of measuring.
    public static func claps(in samples: [Sample], room: Float) -> [Sample] {
        let bar = max(room * 3, 0.03)
        var found: [Sample] = []
        for s in samples where s.peak > bar {
            if let last = found.last, s.at - last.at < separation {
                // Same clap; keep whichever sample of it was loudest.
                if s.peak > last.peak { found[found.count - 1] = s }
            } else {
                found.append(s)
            }
        }
        return found
    }

    /// The quiet part of the recording, which is the room.
    public static func roomLevel(in samples: [Sample]) -> Float {
        guard !samples.isEmpty else { return 0.02 }
        let sorted = samples.map(\.peak).sorted()
        // The 25th percentile: the median would be dragged up by the clapping in a short
        // recording where a good fraction of it is clapping.
        return max(0.002, sorted[sorted.count / 4])
    }

    /// Sensitivity that would let these claps through with room to spare.
    ///
    /// Solved against the dial rather than written as fixed numbers, so there is still
    /// one control afterwards and the user can move it.
    ///
    /// Solved from `ClapDetector.floorAt` and `.ratioAt` rather than from copies of the
    /// numbers, so a change to the dial cannot leave this recommending settings that do
    /// not mean what it thinks.
    public static func recommend(claps: [Sample], room: Float) -> Float {
        guard !claps.isEmpty else { return 0.35 }
        let peaks = claps.map(\.peak).sorted()
        // The quietest clap that is not an outlier: if one of five was feeble, the dial
        // should not be set by it, but four of five should get through.
        let typical = peaks[max(0, peaks.count / 5)]

        // Aim to sit at half the typical clap, so a slightly quieter one still passes.
        let wantedFloor = typical * 0.5
        let forFloor = (ClapDetector.floorAt.0 - wantedFloor) / ClapDetector.floorAt.1

        // And the same margin on the ratio against the room.
        let wantedRatio = max(3, (typical / max(room, 0.002)) * 0.5)
        let forRatio = (ClapDetector.ratioAt.0 - wantedRatio) / ClapDetector.ratioAt.1

        // Whichever needs the looser setting wins — both rules have to pass.
        return min(1, max(0, max(forFloor, forRatio)))
    }

    public static func analyse(_ samples: [Sample]) -> Result {
        let room = roomLevel(in: samples)
        let found = claps(in: samples, room: room)
        let sensitivity = recommend(claps: found, room: room)

        let advice: String
        switch found.count {
        case 0:
            advice = "I didn't hear anything loud enough to be a clap. Try again, closer to the Mac."
        case 1:
            advice = "I only caught one. Clap twice, about a quarter of a second apart."
        default:
            let loudest = found.map(\.peak).max() ?? 0
            let db = loudest <= 0 ? "—" : String(format: "%.0f dB", 20 * log10(loudest))
            advice = "Heard \(found.count) claps, loudest at \(db). Setting the dial to match."
        }
        return Result(claps: found, room: room, sensitivity: sensitivity, advice: advice)
    }
}
