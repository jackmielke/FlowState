import Foundation

/// Backdrops that move.
///
/// The painted places in `SceneArt` are stills that shimmer: a sky, a ridgeline, a little
/// twinkle. These are the opposite — no landform at all, just something flowing. Water,
/// cloud, light through silk. They are what you want behind a long conversation, where a
/// recognisable place starts to feel like a screensaver stuck on one frame.
///
/// Everything in this file is deliberately free of SwiftUI, AppKit and Metal, because it
/// is the part with rules worth proving: which of three renderers a style ends up on, and
/// how often that renderer is allowed to redraw. `MotionBackdropView` does the drawing
/// and owns none of those decisions.
public enum MotionStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case ocean, clouds, aurora, fluid, silk, nebula, rain, embers, prism

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ocean:  return "Ocean"
        case .clouds: return "Clouds"
        case .aurora: return "Aurora"
        case .fluid:  return "Fluid"
        case .silk:   return "Silk"
        case .nebula: return "Nebula"
        case .rain:   return "Rain"
        case .embers: return "Embers"
        case .prism:  return "Prism"
        }
    }

    public var blurb: String {
        switch self {
        case .ocean:  return "Swell moving toward you, foam catching the light."
        case .clouds: return "Low cloud drifting across a dim sky. The slowest one here."
        case .aurora: return "Green and violet curtains, folding."
        case .fluid:  return "Warm colour bleeding through colour, like ink in water."
        case .silk:   return "Caustics — light bent through something rippling."
        case .nebula: return "Deep space, very slowly turning over."
        case .rain:   return "Rain down a dark window, with the light somewhere behind it."
        case .embers: return "Sparks lifting off something warm, going out as they rise."
        case .prism:  return "One slow band of split light, sliding across the dark."
        }
    }

    /// Four stops, dark to bright, given as hex so a palette reads as a palette. The
    /// renderers all take exactly four: the shader binds them to `c0…c3`, the painted
    /// fallback layers them back to front.
    public var palette: [UInt32] {
        switch self {
        case .ocean:  return [0x03121F, 0x0A3A4A, 0x1E7E8C, 0xA9E8E0]
        case .clouds: return [0x0A0E1A, 0x1E2740, 0x4A5573, 0xC9D3E8]
        case .aurora: return [0x02060E, 0x0B3A2E, 0x1FA37A, 0x9BE0C8]
        case .fluid:  return [0x120A1E, 0x3A1B4E, 0x8C3F7A, 0xE0875A]
        case .silk:   return [0x07070C, 0x1A1430, 0x5B4A8C, 0xD8CBE8]
        case .nebula: return [0x03030A, 0x141033, 0x4B1E6B, 0xC24E7A]
        case .rain:   return [0x05080E, 0x141C2A, 0x36485E, 0xB6C6D6]
        case .embers: return [0x0A0503, 0x2A0F06, 0x8C3B12, 0xF2B472]
        case .prism:  return [0x04050C, 0x1B1A44, 0x2E7C93, 0xE8D6A6]
        }
    }

    /// Multiplier on the clock. Tuned by eye: water reads as water at roughly its own
    /// pace, cloud has to be slower than feels right on a preview tile or it looks like
    /// weather on fast-forward once it is full screen.
    public var speed: Double {
        switch self {
        case .ocean:  return 1.00
        case .clouds: return 0.45
        case .aurora: return 0.70
        case .fluid:  return 0.55
        case .silk:   return 0.85
        case .nebula: return 0.35
        case .rain:   return 0.90
        case .embers: return 0.50
        case .prism:  return 0.30
        }
    }

    /// The `[[stitchable]]` function in `Resources/Shaders/Motion.metal`. Kept as a
    /// string on purpose: nothing in this target can see Metal, and the name is the whole
    /// contract between the two files.
    public var shaderFunction: String { "motion_" + rawValue }

    /// Base name of a video loop that would stand in for the shader — `ocean.mp4`.
    public var assetBaseName: String { rawValue }

    /// The moment a *still* of this style is taken from.
    ///
    /// Every still in the app comes from here: the frozen frame under Reduce Motion, the
    /// frozen frame behind an occluded window, and the preview thumbnails. It is not zero,
    /// and that is the whole point — t = 0 is the one moment every one of these looks like
    /// a flat gradient, so a still taken there says nothing about the style it is meant to
    /// be advertising. Twelve seconds in, each is mid-flow.
    ///
    /// Multiplied by `speed` so the slow styles get the same *amount* of development as
    /// the fast ones rather than the same number of seconds.
    public var stillPhase: Double { 12.0 * speed }
}

/// Where a moving backdrop's pixels come from, in the order they are preferred.
public enum MotionSource: Equatable, Sendable {
    /// A video loop found on disk. Cheapest of the three to play and the only one that
    /// can be actual footage of a real place.
    case asset(URL)
    /// The Metal shader in the app bundle. The normal case.
    case shader
    /// Layered gradients drawn in `Canvas`. Not a degraded shader — a different, simpler
    /// picture that costs no Metal library and works from a bare SPM binary.
    case painted
}

/// Resolves a style to something that can actually be drawn.
///
/// The fallback chain is the point. A user with a video loop gets the loop; everyone else
/// gets the shader; anyone running the executable outside the `.app` — `swift run`, a
/// test host, a build where the Metal toolchain was missing — gets the painted version
/// rather than a crash, because `ShaderLibrary.default` does not fail politely when the
/// metallib it wants is not there.
public enum MotionAssets {
    /// Container formats `AVPlayer` handles without a detour. Checked in this order, so a
    /// folder holding both `ocean.mov` and `ocean.mp4` resolves the same way every launch.
    public static let extensions = ["mov", "mp4", "m4v"]

    /// Every path a loop for `style` could be at, best first.
    ///
    /// Directories are searched in the order given — the caller passes the user's own
    /// folder before the bundle's, so dropping a file in beats what shipped.
    public static func candidates(for style: MotionStyle, in directories: [URL]) -> [URL] {
        directories.flatMap { dir in
            extensions.map { dir.appendingPathComponent(style.assetBaseName + "." + $0) }
        }
    }

    /// Nothing here is licensed, and nothing here is downloaded.
    ///
    /// Worth stating in the source rather than only in the README, because it is the
    /// constraint that decides what a new style is allowed to be: every built-in style is
    /// a calculation — a shader, or gradients in a `Canvas` — so the app stays about two
    /// megabytes, ships no third-party media, and carries no attribution obligation to
    /// anybody. Stock footage would break all three. A user's own loop is the one asset
    /// that ever reaches the disk, it stays on their machine, and it is theirs.
    public static let provenance =
        "Every style here is drawn by the app — a GPU shader, or gradients in a Canvas. "
        + "No stock footage, no bundled media, nothing with a licence attached. A loop you "
        + "add yourself stays on this Mac and stays yours."

    /// - Parameters:
    ///   - exists: asked about each candidate, so this stays decidable in a test.
    ///   - broken: a candidate that is on disk but could not be played. Skipped rather
    ///     than returned, so a corrupt `ocean.mov` lets `ocean.mp4` beside it win instead
    ///     of the backdrop going black. Defaults to "nothing is broken", which is what
    ///     every caller wants before anything has actually failed.
    public static func asset(for style: MotionStyle,
                             in directories: [URL],
                             exists: (URL) -> Bool,
                             broken: (URL) -> Bool = { _ in false }) -> URL? {
        candidates(for: style, in: directories).first { exists($0) && !broken($0) }
    }

    /// - Parameters:
    ///   - assetsEnabled: the user's "prefer a video loop when there is one" switch. Off
    ///     sends everyone to the shader, which is the setting to reach for when a loop
    ///     turns out to be uglier or heavier than the drawn version.
    ///   - shaderAvailable: whether a Metal library is really in the bundle. Never assume
    ///     this — see the note above.
    ///   - broken: loops that failed to play. See `asset(for:in:exists:broken:)`. A style
    ///     whose every candidate is broken falls through to the shader, which is the
    ///     difference between a bad file costing you one backdrop and costing you the
    ///     picture entirely.
    public static func source(for style: MotionStyle,
                              directories: [URL],
                              assetsEnabled: Bool,
                              shaderAvailable: Bool,
                              exists: (URL) -> Bool,
                              broken: (URL) -> Bool = { _ in false }) -> MotionSource {
        if assetsEnabled,
           let url = asset(for: style, in: directories, exists: exists, broken: broken) {
            return .asset(url)
        }
        return shaderAvailable ? .shader : .painted
    }
}

/// What a video loop has to be before it is copied into the Motion folder.
///
/// Two separate jobs, and only the first is obvious. The container check is what keeps
/// `AVPlayer` from being handed something it will fail on later, in a view with nowhere to
/// show an error. The size cap is the safe default: this folder lives inside the same
/// directory as the transcripts, it is written to by a file picker, and a decorative
/// backdrop has no business quietly putting four gigabytes there because a stock site
/// offered a 4K master. Both refusals happen before anything is copied, and both say why.
public enum MotionAssetPolicy {

    /// Generous for a seamless loop — they are seconds long — and far below anything that
    /// would be a problem to keep.
    public static let maxBytes = 512 * 1024 * 1024

    /// Why this file cannot be installed, or nil if it can.
    ///
    /// - Parameter bytes: nil when the size could not be read, which is not by itself a
    ///   reason to refuse — an unreadable file fails honestly at the copy instead.
    public static func rejection(name: String, extension ext: String, bytes: Int?) -> String? {
        guard MotionAssets.extensions.contains(ext.lowercased()) else {
            return "\(name) is not a .mov, .mp4 or .m4v."
        }
        if let bytes, bytes > maxBytes {
            return "\(name) is \(bytes / 1_048_576) MB — the limit is \(maxBytes / 1_048_576) MB. "
                 + "A backdrop loop only needs to be a few seconds long."
        }
        return nil
    }
}

/// How often a moving backdrop is allowed to redraw.
///
/// A full-screen animation behind a voice assistant is on for hours, so the honest
/// default is "as slow as still looks like motion", not "as fast as the display goes".
/// A shader costs one GPU pass and can afford 30; the painted fallback is dozens of
/// gradient fills through `Canvas` and is given less. Neither runs at all when nobody
/// can see it.
public enum MotionBudget {
    /// Frames per second, or 0 for "draw one frame and stop".
    ///
    /// - Parameters:
    ///   - occluded: the window is behind something, minimised, or on another Space.
    ///     macOS tells us this; ignoring it is how a backdrop quietly costs battery all
    ///     afternoon.
    ///   - reduceMotion: the system accessibility setting. It means what it says, so the
    ///     backdrop becomes a still image rather than a slower animation — the styles are
    ///     all built to look like something at t = 0.
    ///   - preview: a 40-point tile in Settings, where nobody is looking for detail.
    public static func fps(source: MotionSource,
                           occluded: Bool = false,
                           reduceMotion: Bool = false,
                           preview: Bool = false) -> Double {
        if occluded || reduceMotion { return 0 }
        switch source {
        // The player has its own clock; SwiftUI does not need to tick for it at all.
        case .asset:   return 0
        case .shader:  return preview ? 15 : 30
        case .painted: return preview ? 8  : 20
        }
    }

    /// Seconds between frames, or nil when the answer is "never redraw".
    public static func interval(source: MotionSource,
                                occluded: Bool = false,
                                reduceMotion: Bool = false,
                                preview: Bool = false) -> Double? {
        let f = fps(source: source, occluded: occluded, reduceMotion: reduceMotion, preview: preview)
        return f > 0 ? 1 / f : nil
    }
}
