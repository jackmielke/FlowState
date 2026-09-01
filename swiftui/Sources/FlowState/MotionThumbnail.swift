import SwiftUI
import AppKit
import AVFoundation
import FlowStateCore

/// Stills of the moving backdrops, and the thing that is on screen before one arrives.
///
/// Three separate holes this fills, all of which look the same to a user — a rectangle
/// that is briefly, or permanently, nothing:
///
/// 1. **A video loop takes a moment to spool up.** `AVPlayerLayer` shows black until the
///    first frame is decoded, which on a cold cache is long enough to read as a flash.
/// 2. **`ImageRenderer` cannot run a Metal shader.** Anything rendered offscreen — the
///    snapshot tool, a thumbnail — gets an empty rectangle from `.colorEffect`, not the
///    backdrop. Stills therefore have to come from the drawn form, which is pure SwiftUI.
/// 3. **A tile has to look like something on its first frame.** Nine of these appear at
///    once in Settings and each one starts as whatever its renderer has ready, which is
///    nothing at all.
///
/// So: a palette gradient is painted instantly and always, a real still is generated once
/// per style and swapped in behind, and neither of them ever fails — which is what makes
/// this the bottom of the fallback chain rather than another thing that can go wrong.
@MainActor
enum MotionThumbnail {

    /// The size stills are generated at. Small on purpose: they sit *behind* a live
    /// renderer and are only ever seen for a frame or two, or when everything above them
    /// has failed, and a 16:9 tile at this size costs about a millisecond to draw.
    static let size = CGSize(width: 192, height: 108)

    private static var stills: [MotionStyle: NSImage] = [:]
    private static var posters: [String: NSImage] = [:]
    private static var posterTasks: Set<String> = []

    // MARK: - Stills of a style

    /// The still for `style`, if one has already been generated.
    ///
    /// Deliberately does not generate on demand: this is read from inside a view body, and
    /// a body that runs `ImageRenderer` is a body that hitches. `prepare` is the way in.
    static func still(for style: MotionStyle) -> NSImage? { stills[style] }

    /// Generates the still for `style` unless it is already there.
    ///
    /// Cheap enough to call from `.task` on every appearance — the second call onward is a
    /// dictionary lookup.
    @discardableResult
    static func prepare(_ style: MotionStyle) -> NSImage? {
        if let hit = stills[style] { return hit }

        // The drawn form, frozen at the same moment the app freezes it under Reduce
        // Motion. Not the shader: see the note above — `ImageRenderer` would hand back an
        // empty rectangle and the "thumbnail" would be a lie about how the style looks.
        let view = PaintedMotion(style: style, intensity: 0.6, energy: 0, phase: style.stillPhase)
            .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        stills[style] = image
        return image
    }

    /// Generates every style's still, off the first frame.
    ///
    /// One pass over nine small canvases. Called from Settings rather than at launch,
    /// because a user who never opens the Look tab should not pay for it.
    static func prepareAll() {
        for style in MotionStyle.allCases { prepare(style) }
    }

    // MARK: - Poster frames for a video loop

    /// The first frame of an installed loop, if it has been fetched.
    static func poster(for url: URL) -> NSImage? { posters[url.path] }

    /// Fetches the first frame of `url`, once, and caches it.
    ///
    /// Doubles as a liveness check — a file whose first frame cannot be produced is a file
    /// `AVPlayer` is not going to show either, so it is reported broken here and
    /// `MotionAssetHealth` takes the style back to the shader rather than leaving a black
    /// rectangle behind the conversation.
    @discardableResult
    static func preparePoster(for url: URL) async -> NSImage? {
        let key = url.path
        if let hit = posters[key] { return hit }
        // Two tiles can ask for the same loop in the same frame. Without this the file is
        // decoded twice and, if it is broken, reported broken twice.
        guard !posterTasks.contains(key) else { return nil }
        posterTasks.insert(key)
        defer { posterTasks.remove(key) }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        // A frame slightly in, not frame zero: plenty of loops open on a fade from black,
        // and a black poster is the flash this exists to prevent.
        let at = CMTime(seconds: 0.4, preferredTimescale: 600)
        guard let (cg, _) = try? await generator.image(at: at) else {
            MotionAssetHealth.markBroken(url, reason: "no readable video frame")
            return nil
        }
        let image = NSImage(cgImage: cg, size: .zero)
        posters[key] = image
        return image
    }

    /// Forgets a loop's poster. Called when one is replaced or removed, so the tile does
    /// not go on showing the frame of a file that is no longer there.
    static func forgetPoster(for url: URL) {
        posters.removeValue(forKey: url.path)
        posterTasks.remove(url.path)
    }
}

/// What is behind a moving backdrop before — or instead of — its renderer.
///
/// Always drawn, always underneath, never animated. The gradient costs one fill and is
/// available on the very first frame; the generated still replaces it as soon as there is
/// one. Between them, a `MotionBackdropView` is never an empty rectangle, whatever has
/// gone wrong above: no metallib, no video frame, a style whose shader failed to bind.
struct MotionPlaceholder: View {
    let style: MotionStyle
    /// Set for the tile that is showing an installed loop, so the placeholder underneath
    /// is that loop's own first frame rather than a drawing of the style it replaced.
    var assetURL: URL?

    @State private var still: NSImage?
    @State private var poster: NSImage?

    var body: some View {
        ZStack {
            // The floor. Four palette stops, top to bottom, in the order the style
            // declares them — dark where the chrome sits, bright through the middle.
            LinearGradient(colors: [style.colors[0], style.colors[1], style.colors[2]],
                           startPoint: .top, endPoint: .bottom)

            if let image = poster ?? still {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: style) { still = MotionThumbnail.prepare(style) }
        .task(id: assetURL) {
            guard let assetURL else { poster = nil; return }
            if let cached = MotionThumbnail.poster(for: assetURL) {
                poster = cached
            } else {
                poster = await MotionThumbnail.preparePoster(for: assetURL)
            }
        }
    }
}
