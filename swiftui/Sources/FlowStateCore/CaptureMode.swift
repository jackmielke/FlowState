import Foundation

/// What a recording is a recording *of*.
///
/// Audio-only is the original behaviour and stays the default: both halves of the
/// conversation, mixed, written as a WAV to the same folder as always. The three video
/// modes are additive — they keep that audio, in the same mixdown, and put pictures
/// beside it in a QuickTime movie.
///
/// The four cases are the two independent switches (screen, camera) enumerated rather
/// than stored as two booleans, because a mode is one choice the user makes in one
/// control, and "audio + neither" and "audio only" must not be two different states that
/// have to be kept in agreement.
public enum CaptureMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Microphone + the model's voice. A WAV, exactly as before video existed.
    case audioOnly = "audio"
    /// …plus what is on the chosen display.
    case audioScreen = "audioScreen"
    /// …plus the face camera.
    case audioCamera = "audioCamera"
    /// …plus both, camera composited into the corner of the screen.
    case full = "audioScreenCamera"

    public var id: String { rawValue }

    /// One word, because these sit in a four-segment picker inside a 440-point pane.
    public var label: String {
        switch self {
        case .audioOnly:   return "Audio"
        case .audioScreen: return "Screen"
        case .audioCamera: return "Camera"
        case .full:        return "Both"
        }
    }

    /// What a menu row says, where there is room for the whole thought.
    public var menuLabel: String {
        switch self {
        case .audioOnly:   return "Audio only"
        case .audioScreen: return "Audio + screen"
        case .audioCamera: return "Audio + camera"
        case .full:        return "Audio + screen + camera"
        }
    }

    public var symbol: String {
        switch self {
        case .audioOnly:   return "waveform"
        case .audioScreen: return "display"
        case .audioCamera: return "person.crop.square"
        case .full:        return "rectangle.inset.bottomright.filled"
        }
    }

    /// The sentence under the picker. Says what is captured and what it costs, because
    /// the difference between these four is mostly a difference in file size.
    public var blurb: String {
        switch self {
        case .audioOnly:
            return "Your voice and its replies, mixed into one WAV. Nothing extra is captured, and nothing extra is asked of macOS."
        case .audioScreen:
            return "The same audio, plus what is on the display you picked, in one QuickTime movie. Needs Screen Recording permission."
        case .audioCamera:
            return "The same audio, plus your face camera. Needs Camera permission. Smaller than a screen recording — a camera frame is much less detailed than a desktop."
        case .full:
            return "Screen with the camera composited into the corner. The largest and the most work for the CPU, because every frame is drawn twice."
        }
    }

    public var capturesScreen: Bool { self == .audioScreen || self == .full }
    public var capturesCamera: Bool { self == .audioCamera || self == .full }
    public var isVideo: Bool { capturesScreen || capturesCamera }

    /// `wav` for audio, `mov` for anything with pictures.
    ///
    /// QuickTime rather than MP4 on purpose: `.mov` is what AVFoundation writes natively,
    /// it carries HEVC and H.264 equally happily, and it is the container macOS's own
    /// screen recorder produces — so QuickLook renders a poster frame for it in the
    /// result card with no extra work.
    public var fileExtension: String { isVideo ? "mov" : "wav" }

    /// Which system permission has to be in hand before this mode can start. Reported as
    /// a list because `.full` needs both, and a mode that fails halfway through with one
    /// of the two missing is worse than one that refuses up front.
    public var requiredPermissions: [CapturePermission] {
        var out: [CapturePermission] = [.microphone]
        if capturesScreen { out.append(.screen) }
        if capturesCamera { out.append(.camera) }
        return out
    }
}

/// A permission a mode depends on. Named here so the pre-flight message can be written
/// once, in one voice, rather than at each of the three call sites that check.
public enum CapturePermission: String, Sendable, CaseIterable {
    case microphone, screen, camera

    public var name: String {
        switch self {
        case .microphone: return "Microphone"
        case .screen:     return "Screen Recording"
        case .camera:     return "Camera"
        }
    }

    /// Where in System Settings the switch actually is. Getting this wrong sends people
    /// hunting through a pane that does not contain the row they were told to find.
    public var settingsPath: String {
        "Privacy & Security › \(self == .screen ? "Screen & System Audio Recording" : name)"
    }
}

/// The encoder the movie is written with.
///
/// Both are hardware-accelerated on every Mac this app runs on, so neither is a
/// software-encode disaster — but they are not equivalent:
///
///  * **HEVC** is roughly 35–45% smaller than H.264 at the same visual quality, which is
///    the whole reason it is the default. Its encoder does more work per frame, and on an
///    Intel Mac with a busy GPU that work shows up as heat and fan.
///  * **H.264** is the compatibility floor and the cheapest thing to encode. Anything
///    that plays video plays it — including a decade of Windows machines, web upload
///    forms, and every editor ever shipped.
public enum CaptureCodec: String, Codable, Sendable {
    case hevc, h264

    public var label: String { self == .hevc ? "HEVC" : "H.264" }

    public var blurb: String {
        self == .hevc
            ? "Smaller files, a little more work per frame."
            : "Bigger files, plays absolutely everywhere, cheapest to encode."
    }

    /// Bits per pixel per frame, used to pick a bit rate. Screen content is mostly flat
    /// colour and static text, which both codecs compress far better than camera video,
    /// so these are well under the figures you would use for filmed footage.
    public var bitsPerPixel: Double { self == .hevc ? 0.07 : 0.11 }
}

/// How hard the recorder is allowed to work, and how much disk it is allowed to spend.
///
/// Three named points rather than a pile of sliders. The two ends are the two ways a
/// video recording goes wrong on a laptop — it fills the disk, or it makes the fans
/// audible in the recording — and each end fixes one of them:
///
///  * `.lowStorage` — half the frame rate and a 1280-pixel long edge. About a fifth the
///    size of `.balanced`, and legible for anything that is mostly text.
///  * `.balanced` — the default. 1080p-class, 24 fps, HEVC.
///  * `.lowCPU` — H.264 instead of HEVC and no camera compositing pass beyond the one
///    that is unavoidable. Bigger files, the least encoder work, and the safest choice on
///    an older Intel Mac or when something else is already pinning the machine.
public enum PerformanceProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case lowStorage, balanced, lowCPU

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .lowStorage: return "Small"
        case .balanced:   return "Balanced"
        case .lowCPU:     return "Light"
        }
    }

    public var blurb: String {
        switch self {
        case .lowStorage:
            return "1280 px at 10 fps, HEVC. Roughly a fifth the size of Balanced — fine for anything that is mostly text, choppy for anything that moves."
        case .balanced:
            return "1080p at 24 fps, HEVC. What a screen recording is normally expected to look like."
        case .lowCPU:
            return "1600 px at 24 fps, H.264. The least work for the encoder and the widest compatibility, at about 1.6× the size of Balanced."
        }
    }

    public var symbol: String {
        switch self {
        case .lowStorage: return "arrow.down.circle"
        case .balanced:   return "circle.righthalf.filled"
        case .lowCPU:     return "bolt.circle"
        }
    }

    /// Frames per second written to the file. Capture is requested at the same rate, so
    /// this is a CPU dial as much as a size dial — a frame that is never captured costs
    /// nothing to encode.
    public var frameRate: Int {
        switch self {
        case .lowStorage: return 10
        case .balanced:   return 24
        case .lowCPU:     return 24
        }
    }

    /// Longest edge of the screen track, in pixels. A 6K display recorded at native
    /// resolution is nobody's intention: it is 4× the pixels of 1080p for detail that is
    /// invisible on playback.
    public var screenLongEdge: Int {
        switch self {
        case .lowStorage: return 1280
        case .balanced:   return 1920
        case .lowCPU:     return 1600
        }
    }

    /// Longest edge of the camera track, or of the inset in `.full`. Face cameras top out
    /// around 1080p and there is nothing in a talking head that needs more.
    public var cameraLongEdge: Int {
        switch self {
        case .lowStorage: return 640
        case .balanced:   return 1280
        case .lowCPU:     return 1280
        }
    }

    public var codec: CaptureCodec { self == .lowCPU ? .h264 : .hevc }
}

/// A concrete plan: what size, at what rate, in which codec.
///
/// Separated from `PerformanceProfile` because the profile is a preference and this is
/// the arithmetic done against a particular display — a 5K iMac and a 1440p monitor
/// produce very different plans from the same profile, and it is the plan, not the
/// preference, that the storage warning has to be computed from.
public struct CapturePlan: Equatable, Sendable {
    public let mode: CaptureMode
    public let profile: PerformanceProfile
    /// Output dimensions of the video track. `(0, 0)` for audio-only.
    public let width: Int
    public let height: Int
    public let frameRate: Int
    public let codec: CaptureCodec
    /// Target video bit rate in bits per second. Zero for audio-only.
    public let videoBitRate: Int

    public init(mode: CaptureMode,
                profile: PerformanceProfile,
                width: Int,
                height: Int,
                frameRate: Int,
                codec: CaptureCodec,
                videoBitRate: Int) {
        self.mode = mode
        self.profile = profile
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.videoBitRate = videoBitRate
    }

    /// Nothing below this is worth writing — a bit rate under half a megabit turns text
    /// into porridge no matter how small the frame is.
    public static let minimumBitRate = 500_000
    /// And nothing above this buys anything a screen recording can show. It is also the
    /// guard that stops a 6K display from asking for a 40 Mbit stream.
    public static let maximumBitRate = 12_000_000

    /// Scales a source frame down to fit `longEdge`, never up, and lands on even numbers.
    ///
    /// Even dimensions are not cosmetic: H.264 and HEVC encode chroma at half resolution
    /// in each axis, so an odd width or height is either rejected outright by the encoder
    /// or silently padded, and the padding shows up as a green stripe down one side of
    /// every frame. Rounding to even is the cheapest way to never see that stripe.
    public static func fit(width: Int, height: Int, longEdge: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0, longEdge > 0 else { return (0, 0) }
        let longest = max(width, height)
        // Never upscale: a 720p camera blown up to 1920 is the same picture with four
        // times the bit rate.
        let scale = min(1.0, Double(longEdge) / Double(longest))
        func even(_ v: Double) -> Int { max(2, Int((v * 0.5).rounded()) * 2) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    /// Builds the plan for one source size.
    ///
    /// - Parameters:
    ///   - screen: pixel size of the display being captured, or nil when it is not.
    ///   - camera: pixel size of the camera, or nil when it is not being captured.
    public static func make(mode: CaptureMode,
                            profile: PerformanceProfile,
                            screen: (width: Int, height: Int)? = nil,
                            camera: (width: Int, height: Int)? = nil) -> CapturePlan {
        guard mode.isVideo else {
            return CapturePlan(mode: mode, profile: profile, width: 0, height: 0,
                               frameRate: 0, codec: profile.codec, videoBitRate: 0)
        }

        // In `.full` the movie is the size of the screen track — the camera is drawn into
        // a corner of it, not beside it — so the screen wins whenever it is there.
        let size: (width: Int, height: Int)
        if mode.capturesScreen, let screen {
            size = fit(width: screen.width, height: screen.height, longEdge: profile.screenLongEdge)
        } else if mode.capturesCamera, let camera {
            size = fit(width: camera.width, height: camera.height, longEdge: profile.cameraLongEdge)
        } else {
            // Nothing has told us what the source looks like yet — the Settings pane asks
            // for an estimate before a display has been resolved. 16:9 at the profile's
            // long edge is the honest stand-in, and it is what the estimate is labelled
            // as: approximate.
            let long = mode.capturesScreen ? profile.screenLongEdge : profile.cameraLongEdge
            size = fit(width: long, height: long * 9 / 16, longEdge: long)
        }

        let pixels = Double(size.width * size.height)
        var bits = pixels * Double(profile.frameRate) * profile.codec.bitsPerPixel
        // The composited inset is extra detail in a corner that was previously static
        // desktop — cheap, but not free. Ten percent, measured against a talking head
        // over a code editor.
        if mode == .full { bits *= 1.10 }
        let rate = min(maximumBitRate, max(minimumBitRate, Int(bits.rounded())))

        return CapturePlan(mode: mode, profile: profile,
                           width: size.width, height: size.height,
                           frameRate: profile.frameRate, codec: profile.codec,
                           videoBitRate: rate)
    }

    /// `1920 × 1080 · 24 fps · HEVC`, for the line under the picker.
    public var summary: String {
        guard mode.isVideo else { return "24 kHz mono WAV" }
        return "\(width) × \(height) · \(frameRate) fps · \(codec.label)"
    }
}
