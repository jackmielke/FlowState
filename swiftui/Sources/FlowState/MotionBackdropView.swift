import SwiftUI
import AppKit
import AVFoundation
import Metal
import FlowStateCore

/// Draws a `MotionStyle`, on whichever of the three renderers is actually available.
///
/// The decision itself lives in `MotionAssets.source` where it can be tested; this view
/// only knows how to paint each of the three answers, and how often it is allowed to.
struct MotionBackdropView: View {
    let style: MotionStyle
    /// 0…1. Amplitude and contrast — never speed, because a backdrop that speeds up is a
    /// backdrop you start watching.
    var intensity: Double = 0.6
    /// Live voice level, 0…1, borrowed from the orb.
    var energy: Double = 0
    /// Whether a video loop on disk is allowed to stand in for the shader.
    var assetsEnabled: Bool = true
    /// A Settings tile rather than the window behind everything: fewer frames, and the
    /// voice nudge switched off so nine of them are not all pulsing at once.
    var preview: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var power = MotionPower.shared

    private var source: MotionSource {
        // Reading the revision is what makes this body depend on it.
        _ = power.assetsRevision
        return MotionLibrary.source(for: style, assetsEnabled: assetsEnabled)
    }

    var body: some View {
        let src = source
        let interval = MotionBudget.interval(source: src,
                                             occluded: !power.visible,
                                             reduceMotion: reduceMotion,
                                             preview: preview)
        GeometryReader { geo in
            ZStack {
                // Always underneath, whichever renderer won. One gradient fill, available
                // on the first frame, and completely covered a moment later — which is the
                // whole point: nothing above it has to be able to draw instantly, and if
                // something above it never draws at all this is still a picture of the
                // style rather than a black rectangle.
                MotionPlaceholder(style: style, assetURL: assetURL(src))

                switch src {
                case .asset(let url):
                    // The player keeps its own clock, so Reduce Motion is honoured by
                    // holding it on one frame rather than by not drawing it.
                    LoopingVideoView(url: url,
                                     paused: !power.visible || reduceMotion,
                                     onFailure: { MotionAssetHealth.markBroken($0, reason: $1) })
                case .shader:
                    timeline(interval) { t in shaded(size: geo.size, t: t) }
                case .painted:
                    timeline(interval) { t in PaintedMotion(style: style,
                                                            intensity: intensity,
                                                            energy: preview ? 0 : energy,
                                                            phase: t) }
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    /// Ticks at the budgeted rate, or hands over a single fixed frame when the budget is
    /// "never" — occluded, or Reduce Motion. The phase is not zero in that case: every
    /// style is composed to look like something mid-flow, and t = 0 is the one moment
    /// they all look like a flat gradient.
    @ViewBuilder
    private func timeline<Content: View>(_ interval: Double?,
                                         @ViewBuilder content: @escaping (Double) -> Content) -> some View {
        if let interval {
            TimelineView(.periodic(from: .now, by: interval)) { tl in
                content(MotionClock.phase(at: tl.date) * style.speed)
            }
        } else {
            content(style.stillPhase)
        }
    }

    /// The loop behind this view, when there is one — so the placeholder underneath can
    /// be that file's own first frame rather than a drawing of the style it stands in for.
    private func assetURL(_ src: MotionSource) -> URL? {
        if case .asset(let url) = src { return url }
        return nil
    }

    private func shaded(size: CGSize, t: Double) -> some View {
        let p = style.colors
        return Rectangle()
            .colorEffect(
                ShaderLibrary.default[dynamicMember: style.shaderFunction](
                    .float2(Float(size.width), Float(size.height)),
                    .float(Float(t)),
                    .float(Float(intensity)),
                    .float(Float(preview ? 0 : energy)),
                    .color(p[0]), .color(p[1]), .color(p[2]), .color(p[3])
                )
            )
    }
}

// MARK: - Clock

enum MotionClock {
    /// Seconds since this launch, not since 2001.
    ///
    /// The shaders take time as a `float`, and `timeIntervalSinceReferenceDate` is ~8×10⁸
    /// — where a 32-bit float's spacing is about 64 seconds. Handed that directly, every
    /// one of these animations freezes solid. Measuring from launch keeps the number
    /// small enough to have a fractional part, without the visible discontinuity a
    /// modulo would introduce.
    static let launch = Date()

    static func phase(at date: Date) -> Double { date.timeIntervalSince(launch) }
}

// MARK: - Where the pixels come from

extension MotionStyle {
    var colors: [Color] { palette.map(Color.init(hex:)) }
}

extension Color {
    init(hex v: UInt32) {
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255,
                  opacity: 1)
    }
}

/// The app-side half of `MotionAssets`: the real folders, the real Metal library, and a
/// memo so neither is interrogated on every frame.
enum MotionLibrary {

    /// Where a user's own loops go. Under the same root as everything else FlowState
    /// keeps, so `VIBEVOICE_HOME` moves them with the transcripts.
    static var userFolder: URL {
        ConversationStore.root.appendingPathComponent("Motion", isDirectory: true)
    }

    /// Loops that shipped inside the bundle. There are none today — the app is two
    /// megabytes and video is not — but the lookup costs nothing and means a build that
    /// wants to include one needs no code change.
    static var bundleFolder: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Motion", isDirectory: true)
    }

    /// The user's folder first: a loop you installed beats one that shipped.
    static var directories: [URL] {
        [userFolder, bundleFolder].compactMap { $0 }
    }

    /// Whether `default.metallib` is really in the bundle.
    ///
    /// This must be checked, not assumed. `ShaderLibrary.default` resolves lazily and
    /// dies at draw time if the library or the function is missing — and it is missing in
    /// two ordinary situations: running `.build/release/FlowState` directly instead of the
    /// bundle, and a `build.sh` run on a Mac whose Metal toolchain is not installed.
    static let shaderAvailable: Bool = {
        guard Bundle.main.url(forResource: "default", withExtension: "metallib") != nil else { return false }
        return MTLCreateSystemDefaultDevice() != nil
    }()

    @MainActor private static var memo: [String: MotionSource] = [:]

    /// Resolution is cached because the view above it redraws whenever the voice level
    /// moves, and hitting the filesystem at 30 Hz to ask the same question is absurd.
    /// `refresh()` is the way back out — Settings calls it after installing a loop.
    @MainActor
    static func source(for style: MotionStyle, assetsEnabled: Bool) -> MotionSource {
        let key = style.rawValue + (assetsEnabled ? "+a" : "-a")
        if let hit = memo[key] { return hit }
        let resolved = MotionAssets.source(
            for: style,
            directories: directories,
            assetsEnabled: assetsEnabled,
            shaderAvailable: shaderAvailable,
            exists: { FileManager.default.fileExists(atPath: $0.path) },
            broken: MotionAssetHealth.isBroken)
        memo[key] = resolved
        return resolved
    }

    /// Drops the memo *and* says so.
    ///
    /// Clearing the cache alone is not enough, and the way it fails is quiet: the window
    /// behind Settings only re-evaluates when something it observes changes, so a loop
    /// installed while the app is running would go on showing the shader until the user
    /// happened to change some other setting. Publishing the change is what closes that.
    @MainActor
    static func refresh() {
        memo.removeAll()
        MotionPower.shared.noteAssetsChanged()
    }

    /// One line for Settings, so it is never a mystery which of the three is on screen.
    ///
    /// The broken-loop case is stated first because it is the only one of the four the
    /// user can do something about, and the only one where what is on screen is not what
    /// they asked for.
    @MainActor
    static func describe(_ source: MotionSource, style: MotionStyle) -> String {
        if let failure = MotionAssetHealth.failure(for: style, in: directories) {
            return failure + " Falling back to the drawn version — remove or replace the file."
        }
        switch source {
        case .asset(let url): return "Playing \(url.lastPathComponent) from your Motion folder."
        case .shader:         return "Drawn live on the GPU — one pass, sharp at any size."
        case .painted:        return "Metal library not in this build — using the drawn fallback."
        }
    }

    /// Copies a chosen video in as `<style>.<ext>`, replacing whatever was there.
    ///
    /// Copied rather than referenced on purpose: a backdrop that points at a file in
    /// Downloads is a backdrop that disappears the week the user tidies up.
    @MainActor
    @discardableResult
    static func install(_ picked: URL, as style: MotionStyle) -> String? {
        let ext = picked.pathExtension.lowercased()
        let bytes = (try? picked.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        // Both refusals happen before anything is copied, and both say why. See
        // `MotionAssetPolicy` for why a size cap belongs here at all.
        if let refusal = MotionAssetPolicy.rejection(name: picked.lastPathComponent,
                                                     extension: ext,
                                                     bytes: bytes) {
            return refusal
        }
        let dest = userFolder.appendingPathComponent(style.assetBaseName + "." + ext)
        do {
            try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
            // Every extension for this style goes, not just the matching one, or an old
            // ocean.mov would keep winning over the ocean.mp4 just installed.
            for candidate in MotionAssets.candidates(for: style, in: [userFolder]) {
                try? FileManager.default.removeItem(at: candidate)
                MotionThumbnail.forgetPoster(for: candidate)
                MotionAssetHealth.forget(candidate)
            }
            try FileManager.default.copyItem(at: picked, to: dest)
        } catch {
            return error.localizedDescription
        }
        refresh()
        return nil
    }

    @MainActor
    static func removeAsset(for style: MotionStyle) {
        for candidate in MotionAssets.candidates(for: style, in: [userFolder]) {
            try? FileManager.default.removeItem(at: candidate)
            MotionThumbnail.forgetPoster(for: candidate)
            // A file that failed is being deleted, so the note about it goes too. Keeping
            // it would mean a replacement at the same path started out condemned.
            MotionAssetHealth.forget(candidate)
        }
        refresh()
    }

    /// Asks for a video loop.
    @MainActor
    static func chooseAsset() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use as backdrop"
        panel.message = "Pick a video loop — seamless ones look best, and it will be muted"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - Loops that turn out not to play

/// Which installed loops failed, so the backdrop can stop trying to play them.
///
/// `MotionAssets.source` picks a loop by asking whether the file is *there*, which is the
/// only question a pure, testable function can answer — and it is the wrong question about
/// half the ways a video file goes wrong. A truncated download, an audio-only `.mp4`, a
/// `.mov` wrapping a codec this Mac has no decoder for: all of them exist, all of them
/// resolve to `.asset`, and all of them then draw nothing. Black, full screen, behind the
/// conversation, with the Settings pane cheerfully reporting "Playing ocean.mp4".
///
/// So playability is discovered where it can be — at the player, and at the poster-frame
/// generator — and remembered here. Resolution consults it, so the very next redraw takes
/// the style back down the chain to the shader.
///
/// In memory only, deliberately. A file that failed because the machine was under load, or
/// because it was still being copied in, deserves another try next launch; a file that is
/// genuinely broken fails again in a fraction of a second and costs nothing to rediscover.
@MainActor
enum MotionAssetHealth {

    private static var broken: [String: String] = [:]

    static func isBroken(_ url: URL) -> Bool { broken[url.path] != nil }

    /// Records a failure and republishes, which is what actually gets the black rectangle
    /// off the screen — clearing the memo alone would leave the window showing the dead
    /// player until something else happened to invalidate it.
    ///
    /// Idempotent: a player can report the same file failing several times in a row, and
    /// refreshing on each of them would be a redraw storm.
    static func markBroken(_ url: URL, reason: String) {
        guard broken[url.path] == nil else { return }
        broken[url.path] = reason
        // Logged as well as shown. What the user sees is one line in Settings they have to
        // be looking at; this is the only trace of it for anyone debugging a backdrop that
        // is not the backdrop they installed.
        FileHandle.standardError.write(
            Data("[motion] \(url.lastPathComponent) unplayable — \(reason); falling back\n".utf8))
        MotionLibrary.refresh()
    }

    static func forget(_ url: URL) { broken.removeValue(forKey: url.path) }

    /// One sentence about this style's loop, if it has one and it failed. Nil is the
    /// ordinary case and means "nothing to report".
    static func failure(for style: MotionStyle, in directories: [URL]) -> String? {
        for url in MotionAssets.candidates(for: style, in: directories) {
            if let reason = broken[url.path] {
                return "\(url.lastPathComponent) could not be played — \(reason)."
            }
        }
        return nil
    }
}

// MARK: - Not drawing when nobody is looking

/// Tracks whether any of the app's windows are actually on screen.
///
/// A full-screen animation runs for hours, and macOS knows perfectly well when it is
/// behind Xcode, minimised, or on another Space. Ignoring that is the difference between
/// a backdrop that is free and one that quietly costs an hour of battery.
@MainActor
final class MotionPower: ObservableObject {
    static let shared = MotionPower()

    @Published private(set) var visible: Bool = true

    /// Bumped whenever the set of installed video loops changes. Views observe this
    /// object anyway for occlusion, so one counter is all it takes for a newly installed
    /// loop to appear behind the Settings pane immediately.
    @Published private(set) var assetsRevision = 0

    func noteAssetsChanged() { assetsRevision &+= 1 }

    private init() {
        visible = NSApp?.occlusionState.contains(.visible) ?? true
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = NSApp?.occlusionState.contains(.visible) ?? true
                    if now != self.visible { self.visible = now }
                }
            }
    }
}

// MARK: - Video loops

/// An `AVPlayerLooper` in an `NSView`, sized to fill.
struct LoopingVideoView: NSViewRepresentable {
    let url: URL
    var paused: Bool
    /// Called when this file turns out not to be playable, with a reason fit to show a
    /// user. The view above uses it to take the style back to the shader — see
    /// `MotionAssetHealth`.
    var onFailure: ((URL, String) -> Void)?

    final class Container: NSView {
        private let queue = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private let playerLayer = AVPlayerLayer()
        private var observers: [NSObjectProtocol] = []
        private(set) var url: URL?
        var onFailure: ((URL, String) -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            queue.isMuted = true
            // A decorative backdrop has no business keeping the display awake.
            queue.preventsDisplaySleepDuringVideoPlayback = false
            playerLayer.player = queue
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)

            // A file can also fail *during* playback — a decoder that gives up partway
            // through, or a volume that disappears from under a loop on an external disk.
            observers.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self, let url = self.url else { return }
                        let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                        self.report(url, error?.localizedDescription ?? "playback stopped")
                    }
                })
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        required init?(coder: NSCoder) { fatalError("not used") }

        private func report(_ url: URL, _ reason: String) {
            onFailure?(url, reason)
        }

        override func layout() {
            super.layout()
            // The layer is repositioned every frame of a window resize; animating that
            // makes the video lag behind the window edge by a visible fraction of a second.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }

        func load(_ next: URL) {
            guard next != url else { return }
            url = next
            let asset = AVURLAsset(url: next)
            looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(asset: asset))

            // Ask the file directly rather than waiting for the player to give up.
            //
            // `isPlayable` catches the container this Mac has no decoder for; the track
            // check catches the case `isPlayable` says yes to and a backdrop still cannot
            // use — an audio-only .mp4, which plays perfectly and draws nothing at all.
            Task { @MainActor [weak self] in
                let playable = (try? await asset.load(.isPlayable)) ?? false
                let hasVideo = ((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty == false
                guard let self, self.url == next else { return }
                if !playable {
                    self.report(next, "this Mac has no decoder for it")
                } else if !hasVideo {
                    self.report(next, "it has no video track")
                }
            }
        }

        func setPaused(_ paused: Bool) {
            if paused { queue.pause() } else if queue.rate == 0 { queue.play() }
        }
    }

    func makeNSView(context: Context) -> Container {
        let v = Container()
        v.onFailure = onFailure
        v.load(url)
        v.setPaused(paused)
        return v
    }

    func updateNSView(_ v: Container, context: Context) {
        v.onFailure = onFailure
        v.load(url)
        v.setPaused(paused)
    }
}

// MARK: - The drawn fallback

/// What a style looks like without Metal.
///
/// Not an approximation of the shader — a simpler picture of the same idea, built out of
/// a few dozen gradient fills instead of a calculation per pixel. Six forms cover the nine
/// styles, because past a certain distance a wave and a ribbon are the same drawing with
/// different numbers.
///
/// The forms are grouped by *movement*, not by palette, which is why the three added with
/// Rain, Embers and Prism could not reuse the first three: something falling, something
/// rising and something sliding across are three drawings, and painting them as drifting
/// blobs in a new colour is exactly how a fallback stops being a picture of the same idea.
private enum PaintedForm { case swell, drift, ribbons, streaks, motes, bands }

private extension MotionStyle {
    var paintedForm: PaintedForm {
        switch self {
        case .ocean, .silk:            return .swell
        case .clouds, .fluid, .nebula: return .drift
        case .aurora:                  return .ribbons
        case .rain:                    return .streaks
        case .embers:                  return .motes
        case .prism:                   return .bands
        }
    }
}

struct PaintedMotion: View {
    let style: MotionStyle
    var intensity: Double = 0.6
    var energy: Double = 0
    var phase: Double = 0

    var body: some View {
        Canvas(rendersAsynchronously: true) { ctx, size in
            let p = style.colors
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(.init(colors: [p[0], p[1], p[2]]),
                                           startPoint: .zero,
                                           endPoint: .init(x: 0, y: size.height)))
            switch style.paintedForm {
            case .swell:   swell(&ctx, size, p)
            case .drift:   drift(&ctx, size, p)
            case .ribbons: ribbons(&ctx, size, p)
            case .streaks: streaks(&ctx, size, p)
            case .motes:   motes(&ctx, size, p)
            case .bands:   bands(&ctx, size, p)
            }
        }
        // One offscreen layer for the whole canvas: the blobs overlap heavily, and
        // compositing them separately is where a fallback like this gets expensive.
        .drawingGroup()
    }

    private var amp: Double { 0.4 + intensity * 0.8 }

    /// Sine bands stacked front to back, each a filled path with its own colour.
    ///
    /// The numbers here are all lower than the first pass, which used a high frequency
    /// and a large near-field amplitude and came out as a range of jagged mountains
    /// rather than water — sampled at 40 points, the peaks were visibly polygonal too.
    /// Long wavelengths, small amplitudes and enough steps to hide the sampling.
    private func swell(_ ctx: inout GraphicsContext, _ size: CGSize, _ p: [Color]) {
        let bands = 7
        for b in 0..<bands {
            let f = Double(b) / Double(bands - 1)          // 0 = far, 1 = near
            let base = size.height * (0.34 + f * 0.72)
            let height = size.height * 0.055 * amp * (0.45 + f * 0.7)
            let k = 1.5 + Double(b) * 0.42
            let speed = 0.30 + f * 0.55

            var path = Path()
            path.move(to: .init(x: 0, y: size.height))
            let steps = 64
            for s in 0...steps {
                let u = Double(s) / Double(steps)
                let y = base
                    - height * sin(u * k * .pi + phase * speed + Double(b) * 1.3)
                    - height * 0.30 * sin(u * k * 1.9 * .pi - phase * speed * 1.4)
                path.addLine(to: .init(x: u * size.width, y: y))
            }
            path.addLine(to: .init(x: size.width, y: size.height))
            path.closeSubpath()

            let tint = p[min(3, 1 + b * 3 / bands)]
            ctx.fill(path, with: .color(tint.opacity(0.16 + f * 0.30)))
            // The crest line is what stops seven filled shapes reading as seven stripes.
            ctx.stroke(path, with: .color(p[3].opacity(0.08 + f * 0.16 * (0.6 + energy))),
                       lineWidth: 1 + f)
        }
    }

    /// Big soft blobs on Lissajous paths. Incommensurable frequencies, so the pattern
    /// never visibly repeats.
    private func drift(_ ctx: inout GraphicsContext, _ size: CGSize, _ p: [Color]) {
        let blobs = 6
        let unit = max(size.width, size.height)
        for b in 0..<blobs {
            let fb = Double(b)
            let sp = 0.11 + fb * 0.017
            let x = size.width * (0.5 + 0.42 * sin(phase * sp + fb * 1.7))
            let y = size.height * (0.5 + 0.36 * cos(phase * sp * 1.31 + fb * 2.3))
            let r = unit * (0.20 + 0.16 * amp) * (0.7 + 0.3 * sin(phase * 0.09 + fb))
            let tint = p[2 + b % 2]
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                     with: .radialGradient(
                        .init(colors: [tint.opacity(0.30 + energy * 0.10), .clear]),
                        center: .init(x: x, y: y), startRadius: 0, endRadius: r))
        }
    }

    /// Curtains: a wandering centre line, drawn as a stack of strokes whose opacity falls
    /// off either side of it.
    private func ribbons(_ ctx: inout GraphicsContext, _ size: CGSize, _ p: [Color]) {
        for c in 0..<3 {
            let fc = Double(c)
            let centre = size.height * (0.30 + fc * 0.13)
            let spread = size.height * 0.055 * amp
            for layer in -4...4 {
                let fl = Double(layer)
                var path = Path()
                let steps = 36
                for s in 0...steps {
                    let u = Double(s) / Double(steps)
                    let wander = sin(u * 3.1 + phase * 0.22 + fc * 2.2) * spread * 1.8
                                + sin(u * 7.3 - phase * 0.15 + fc) * spread * 0.7
                    let y = centre + wander + fl * spread * 0.42
                    if s == 0 { path.move(to: .init(x: 0, y: y)) }
                    else { path.addLine(to: .init(x: u * size.width, y: y)) }
                }
                let falloff = 1 - abs(fl) / 5
                let tint = c == 1 ? p[3] : p[2]
                ctx.stroke(path,
                           with: .color(tint.opacity(0.09 * falloff * falloff * (1 + energy))),
                           lineWidth: spread * 0.8)
            }
        }
    }

    /// Rain: a fixed set of streaks, each falling down its own column at its own rate.
    ///
    /// The positions come from a hash of the streak's index rather than from a random
    /// source, so the picture is the same every launch and — more to the point — the same
    /// every frame of a still. A `Canvas` that reshuffled its contents whenever SwiftUI
    /// felt like re-evaluating it would strobe.
    private func streaks(_ ctx: inout GraphicsContext, _ size: CGSize, _ p: [Color]) {
        // The light behind the glass, so the streaks have something to be lit by.
        let glowR = max(size.width, size.height) * 0.55
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .radialGradient(.init(colors: [p[2].opacity(0.30), .clear]),
                                       center: .init(x: size.width * 0.5, y: size.height * 0.34),
                                       startRadius: 0, endRadius: glowR))

        let count = 90
        for i in 0..<count {
            // Three *independent* hashes, and that is the whole trick. The first version
            // took the column from `h` and the head start down the column from `h` as
            // well, which makes x and y the same number — so the ninety streaks landed on
            // a perfectly straight diagonal instead of scattering across the glass.
            let h = Self.hash(i)                 // which column
            let head = Self.hash(i + 4001)       // how far down it already is
            let h2 = Self.hash(i + 977)          // how near, and so how fast and how long
            let x = size.width * h
            let speed = size.height * (0.22 + 0.34 * h2) * (0.6 + amp * 0.5)
            let length = size.height * (0.05 + 0.13 * h2) * amp
            // Wraps through a span a little taller than the frame, so a streak enters
            // from above rather than appearing at the top edge.
            let span = size.height + length * 2
            let y = (phase * speed + head * span).truncatingRemainder(dividingBy: span) - length

            var path = Path()
            path.move(to: .init(x: x, y: y))
            path.addLine(to: .init(x: x + size.width * 0.006, y: y + length))

            // Near streaks are wider, brighter and faster — the three go together, and
            // that correlation is the only depth cue a drawing this simple has.
            let near = h2
            ctx.stroke(path,
                       with: .linearGradient(
                        .init(colors: [p[3].opacity(0), p[3].opacity(0.10 + near * 0.22)]),
                        startPoint: .init(x: x, y: y),
                        endPoint: .init(x: x, y: y + length)),
                       lineWidth: 0.7 + near * 1.6)
        }
    }

    /// Embers: sparks rising and going out.
    ///
    /// Each one is on a fixed loop of its own length, so they do not all restart together
    /// — the give-away of a particle field drawn without one.
    private func motes(_ ctx: inout GraphicsContext, _ size: CGSize, _ p: [Color]) {
        // The heat they come off, low and off the bottom edge where the buttons are.
        // Weaker and tighter than it first was: at full strength it swamped the sparks
        // entirely and the style came out as an orange gradient with nothing in it.
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .radialGradient(.init(colors: [p[2].opacity(0.22), .clear]),
                                       center: .init(x: size.width * 0.5, y: size.height * 1.08),
                                       startRadius: 0, endRadius: max(size.width, size.height) * 0.50))

        let count = 60
        for i in 0..<count {
            // Independent again: the column, the point in the spark's life, and its size
            // all have to come from different hashes or the field is a diagonal line.
            let h = Self.hash(i)                 // which column it lifted from
            let head = Self.hash(i + 2003)       // how far through its life it already is
            let h2 = Self.hash(i + 613)          // how big, how long it lasts, how far it gets
            let life = 6.0 + h2 * 9.0                       // seconds from lifting to out
            let u = ((phase * (0.5 + amp * 0.4) + head * life)
                        .truncatingRemainder(dividingBy: life)) / life   // 0 = just lit
            let rise = size.height * (0.55 + h2 * 0.4)
            let y = size.height * 0.98 - u * rise
            let x = size.width * h + sin(phase * (0.4 + h2 * 0.6) + h * 12) * size.width * 0.035 * amp
            let r = (1.1 + h2 * 2.2) * (1 - u * 0.45)
            // Brightest just after lifting, gone before the top — and never at full
            // strength right at the bottom edge, so the chrome keeps its dark ground.
            let fade = min(u / 0.14, 1) * (1 - u) * (1 - u)
            let tint = h2 > 0.72 ? p[3] : p[2]
            ctx.fill(Path(ellipseIn: CGRect(x: x - r * 3, y: y - r * 3, width: r * 6, height: r * 6)),
                     with: .radialGradient(
                        .init(colors: [tint.opacity(0.85 * fade * (1 + energy * 0.4)), .clear]),
                        center: .init(x: x, y: y), startRadius: 0, endRadius: r * 3))
        }
    }

    /// Prism: a broad band of light sliding across on the diagonal.
    ///
    /// The dispersion the shader gets for free — sampling the ramp three times and taking
    /// one channel from each — is approximated here by drawing the band three times,
    /// slightly offset, in the three colours that are furthest apart in the palette. Same
    /// idea, a hundredth of the arithmetic.
    private func bands(_ ctx: inout GraphicsContext, _ size: CGSize, _ p: [Color]) {
        // Drawn in a rotated space rather than by aiming a gradient diagonally across the
        // frame. The first version did the latter — two corner points and a `linearGradient`
        // between them — and the maths quietly worked out to a wash over the whole tile
        // with no band in it anywhere. Rotating the context and filling upright rectangles
        // means the beam has a width, in points, that is the width it looks.
        // The shared ground under every painted style runs p0 → p2 top to bottom, which
        // for this palette leaves a bright teal strip along the bottom edge — directly
        // under the buttons. Every other style paints over it; this one is mostly empty
        // frame by design, so it has to put the dark back deliberately.
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(
                    .init(stops: [.init(color: p[0].opacity(0.40), location: 0.0),
                                  .init(color: p[0].opacity(0.18), location: 0.45),
                                  .init(color: p[0].opacity(0.94), location: 1.0)]),
                    startPoint: .zero, endPoint: .init(x: 0, y: size.height)))

        let reach = (size.width + size.height) * 1.3   // long enough to cross any corner
        let angle = -0.62                              // radians; matches the shader's beam
        let halfWidth = reach * (0.032 + 0.026 * amp)

        // How far the beam travels, and this is *not* `reach`.
        //
        // Sizing the sweep to the length of the rectangles being drawn was the first
        // version's mistake: `reach` is 1.3×(w+h), so the beam spent most of its cycle
        // entirely off the side of a frame barely a third that wide and a still taken at
        // any given moment was usually of an empty tile. What the sweep has to match is
        // the frame's half-extent *along the beam's own axis* — the projection of the
        // rectangle onto it, which depends on the angle and not just on the size. Guessing
        // at a fraction of w + h happens to work at one aspect ratio and fails at the next
        // one, and this view is drawn at both a 3:2 tile and a very wide banner.
        let span = (size.width * cos(angle) + size.height * abs(sin(angle))) / 2

        // The offset is what puts the beam in shot at `stillPhase`.
        //
        // Every style here is composed to look like something at the moment the app
        // freezes it — under Reduce Motion, behind another window, in a thumbnail. For the
        // eight styles that fill the frame that is automatic. This one is a single object
        // crossing an otherwise empty frame, so where it is at that moment is a
        // composition decision, and without this it is a picture of the dark just after
        // the beam has left.
        let travel = (phase * 0.05 + 0.32).truncatingRemainder(dividingBy: 1.0)
        let centre = (travel * 2 - 1) * span

        ctx.drawLayer { layer in
            layer.translateBy(x: size.width / 2, y: size.height / 2)
            layer.rotate(by: .radians(angle))

            // Three offset copies in three palette colours: the same trick the shader does
            // by sampling the ramp three times and taking one channel from each, at a
            // hundredth of the arithmetic. The offsets are what make the edges fringe.
            for (i, tint) in [p[1], p[2], p[3]].enumerated() {
                let nudge = (Double(i) - 1) * halfWidth * 0.45
                let x = centre + nudge
                let rect = CGRect(x: x - halfWidth, y: -reach / 2,
                                  width: halfWidth * 2, height: reach)
                layer.fill(Path(rect),
                           with: .linearGradient(
                            .init(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: tint.opacity(i == 2 ? 0.32 : 0.21), location: 0.5),
                                .init(color: .clear, location: 1)
                            ]),
                            startPoint: .init(x: x - halfWidth, y: 0),
                            endPoint: .init(x: x + halfWidth, y: 0)))
            }

            // The narrow core, which is what stops three soft washes reading as fog.
            let core = halfWidth * 0.16
            let rect = CGRect(x: centre - core, y: -reach / 2, width: core * 2, height: reach)
            layer.fill(Path(rect),
                       with: .linearGradient(
                        .init(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: p[3].opacity(0.30 + energy * 0.10), location: 0.5),
                            .init(color: .clear, location: 1)
                        ]),
                        startPoint: .init(x: centre - core, y: 0),
                        endPoint: .init(x: centre + core, y: 0)))
        }
    }

    /// A stable pseudo-random number for index `i`.
    ///
    /// Deliberately not `Double.random`: everything drawn here is re-evaluated whenever
    /// SwiftUI decides to, and a field whose members move when nothing has changed is a
    /// field that strobes. The same index always gives the same number, in this launch and
    /// the next one.
    static func hash(_ i: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + 78.233) * 43758.5453
        return x - x.rounded(.down)
    }
}

// MARK: - Choosing one

/// The moving-backdrop picker: one running at full size, the rest running as thumbnails,
/// and the two controls that apply to whichever is chosen.
///
/// Its own view rather than a stretch of `SettingsView` for a plain reason — it is the
/// one part of Settings that cannot be judged from source or from a still, so it has to
/// be renderable on its own, which `SettingsSnapshot` does. Everything it changes arrives
/// as a binding, so it has no opinion about where those are stored.
struct MotionStyleGallery: View {
    /// Both halves of the Look choice, not just the style.
    ///
    /// A moving background is only on screen when the backdrop is `.motion` as well, so
    /// this gallery has to be able to set both — see `LookSelection.choose(_:)`. It reads
    /// both too: a tile is ringed only when the pair agrees, so a style that is merely
    /// remembered while a photo is up does not claim to be showing.
    @Binding var look: LookSelection
    @Binding var intensity: Double
    @Binding var assetsEnabled: Bool
    /// Why the last chosen file could not be installed. Owned by the caller, because it
    /// describes one click rather than a preference.
    @Binding var installError: String?

    /// The style the controls below apply to: the one showing, or — while a still
    /// backdrop is up — the one that would show.
    private var style: MotionStyle { look.motionStyle }

    /// Where the current style's pixels are coming from, asked once per redraw rather
    /// than per frame.
    private var source: MotionSource {
        MotionLibrary.source(for: style, assetsEnabled: assetsEnabled)
    }

    private var hasAsset: Bool {
        if case .asset = source { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The one at full size, above the rest at thumbnail size. A 48-point tile
            // tells you the palette and nothing about the movement, which is the entire
            // difference between these — so the choice is made in the grid and judged
            // here, without having to close Settings to see it.
            MotionBackdropView(style: style, intensity: intensity, assetsEnabled: assetsEnabled)
                .frame(height: 104)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1))
                .overlay(alignment: .bottomLeading) {
                    Text(style.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                        .padding(9)
                }
                .accessibilityLabel("Preview: \(style.label)")
                .accessibilityValue(style.blurb)
                // The tap target of last resort, and the honest one while a still
                // backdrop is up: the big preview shows what you would get, so clicking
                // it is a way of asking for it.
                .contentShape(Rectangle())
                .onTapGesture { choose(style) }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                      spacing: 12) {
                ForEach(Backdrop.movingBackgrounds) { s in
                    let on = look.isShowing(s)
                    Button {
                        choose(s)
                    } label: {
                        VStack(spacing: 5) {
                            // Every tile here is a live renderer, and a live renderer
                            // inside a Button label swallows the click — which is why
                            // `MotionBackdropView` hit-tests to nothing at all.
                            SwatchFrame(selected: on, radius: 7) {
                                MotionBackdropView(style: s,
                                                   intensity: intensity,
                                                   assetsEnabled: assetsEnabled,
                                                   preview: true)
                                    .frame(height: 48)
                            }
                            .allowsHitTesting(false)
                            Text(s.label)
                                .font(.system(size: 10.5, weight: on ? .medium : .regular))
                                .foregroundStyle(on ? Theme.text : Theme.textDim)
                                .lineLimit(1)
                        }
                        // Without this the button's hit region is whatever its label
                        // hit-tests to — and since the picture above deliberately does
                        // not, that left the 10-point word underneath as the only place
                        // a moving background could be clicked. Half a line of text under
                        // a 48-point tile reads as "not clickable", which is exactly how
                        // this was reported. Stating the shape gives the whole tile back
                        // without letting the renderer eat the click again.
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(s.blurb)
                    .accessibilityLabel("Moving background: \(s.label)")
                    .accessibilityHint(s.blurb)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }

            note(style.blurb)

            // Says out loud what the missing ring says quietly. Both galleries are on
            // screen at once now, so "which of these am I actually looking at" is a
            // question the pane has to answer rather than imply.
            if !look.isShowing(style) {
                note("Not showing — \(look.backdrop.label) is. Click any tile above to switch to a moving background.")
            }

            HStack(spacing: 14) {
                NeatSlider(value: $intensity, range: 0...1)
                    .accessibilityLabel("Motion intensity")
                    .accessibilityValue(String(format: "%.0f%%", intensity * 100))
                Text(String(format: "%.0f%% motion", intensity * 100))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 104, alignment: .trailing)
            }
            note("Amplitude and contrast only — none of these speed up, so the backdrop "
                 + "never starts asking to be watched. At zero it is close to a still gradient.")

            Divider().overlay(Theme.hairline).padding(.vertical, 2)

            HStack(spacing: 8) {
                Button(hasAsset ? "Replace video loop…" : "Use a video loop…") {
                    if let url = MotionLibrary.chooseAsset() {
                        installError = MotionLibrary.install(url, as: style)
                    }
                }
                .buttonStyle(GhostButtonStyle(tint: Theme.accentInk, padH: 11, padV: 6))

                if hasAsset {
                    Button("Remove") {
                        MotionLibrary.removeAsset(for: style)
                        installError = nil
                    }
                    .buttonStyle(GhostButtonStyle(tint: Theme.textDim, padH: 11, padV: 6))
                }
                Spacer()
                Text("Prefer loops")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                NeatToggle(isOn: $assetsEnabled)
                    .accessibilityLabel("Prefer video loops over the shader")
            }

            if let installError {
                note("Could not use that file — " + installError)
            } else {
                note(MotionLibrary.describe(source, style: style)
                     + " Loops live in \(MotionLibrary.userFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
                     + ", named after the style — ocean.mp4, clouds.mov. The switch on the right "
                     + "goes back to the drawn version without deleting anything.")
            }

            // Said in the app, not only in the README. Which of these pictures the app has
            // the right to show is a fair question to have about a backdrop feature, and
            // the answer — all of them, because it draws them itself — is a good one.
            note(MotionAssets.provenance)
        }
        // The stills behind the tiles, generated once, the first time this pane is opened.
        // Not at launch: a user who never opens the Look tab should not pay for nine
        // offscreen canvases they will not see.
        .task { MotionThumbnail.prepareAll() }
    }

    /// Picks `s`, which also means switching the backdrop to `.motion` — the section is on
    /// screen whatever is currently showing, so a click in it has to be a whole choice.
    private func choose(_ s: MotionStyle) {
        withAnimation(.easeOut(duration: 0.18)) { look.choose(s) }
    }

    private func note(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }
}
