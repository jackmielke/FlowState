import SwiftUI
import AppKit
import AVFoundation
import Metal
import VibeVoiceCore

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
    /// voice nudge switched off so six of them are not all pulsing at once.
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
            switch src {
            case .asset(let url):
                // The player keeps its own clock, so Reduce Motion is honoured by holding
                // it on one frame rather than by not drawing it.
                LoopingVideoView(url: url, paused: !power.visible || reduceMotion)
            case .shader:
                timeline(interval) { t in shaded(size: geo.size, t: t) }
            case .painted:
                timeline(interval) { t in PaintedMotion(style: style,
                                                        intensity: intensity,
                                                        energy: preview ? 0 : energy,
                                                        phase: t) }
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
            content(12.0 * style.speed)
        }
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
    /// two ordinary situations: running `.build/release/VibeVoice` directly instead of the
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
            exists: { FileManager.default.fileExists(atPath: $0.path) })
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
    static func describe(_ source: MotionSource) -> String {
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
        guard MotionAssets.extensions.contains(ext) else {
            return "\(picked.lastPathComponent) is not a .mov, .mp4 or .m4v."
        }
        let dest = userFolder.appendingPathComponent(style.assetBaseName + "." + ext)
        do {
            try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
            // Every extension for this style goes, not just the matching one, or an old
            // ocean.mov would keep winning over the ocean.mp4 just installed.
            for candidate in MotionAssets.candidates(for: style, in: [userFolder]) {
                try? FileManager.default.removeItem(at: candidate)
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

    final class Container: NSView {
        private let queue = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private let playerLayer = AVPlayerLayer()
        private(set) var url: URL?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            queue.isMuted = true
            // A decorative backdrop has no business keeping the display awake.
            queue.preventsDisplaySleepDuringVideoPlayback = false
            playerLayer.player = queue
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

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
            looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: next))
        }

        func setPaused(_ paused: Bool) {
            if paused { queue.pause() } else if queue.rate == 0 { queue.play() }
        }
    }

    func makeNSView(context: Context) -> Container {
        let v = Container()
        v.load(url)
        v.setPaused(paused)
        return v
    }

    func updateNSView(_ v: Container, context: Context) {
        v.load(url)
        v.setPaused(paused)
    }
}

// MARK: - The drawn fallback

/// What a style looks like without Metal.
///
/// Not an approximation of the shader — a simpler picture of the same idea, built out of
/// a few dozen gradient fills instead of a calculation per pixel. Three forms cover the
/// six styles, because past a certain distance a wave and a ribbon are the same drawing
/// with different numbers.
private enum PaintedForm { case swell, drift, ribbons }

private extension MotionStyle {
    var paintedForm: PaintedForm {
        switch self {
        case .ocean, .silk:            return .swell
        case .clouds, .fluid, .nebula: return .drift
        case .aurora:                  return .ribbons
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
}

// MARK: - Choosing one

/// The moving-backdrop picker: one running at full size, six running as thumbnails, and
/// the two controls that apply to whichever is chosen.
///
/// Its own view rather than a stretch of `SettingsView` for a plain reason — it is the
/// one part of Settings that cannot be judged from source or from a still, so it has to
/// be renderable on its own, which `SettingsSnapshot` does. Everything it changes arrives
/// as a binding, so it has no opinion about where those are stored.
struct MotionStyleGallery: View {
    @Binding var style: MotionStyle
    @Binding var intensity: Double
    @Binding var assetsEnabled: Bool
    /// Why the last chosen file could not be installed. Owned by the caller, because it
    /// describes one click rather than a preference.
    @Binding var installError: String?

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
            // The one at full size, above the six at thumbnail size. A 48-point tile
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

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                      spacing: 12) {
                ForEach(MotionStyle.allCases) { s in
                    let on = style == s
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { style = s }
                    } label: {
                        VStack(spacing: 5) {
                            SwatchFrame(selected: on, radius: 7) {
                                MotionBackdropView(style: s,
                                                   intensity: intensity,
                                                   assetsEnabled: assetsEnabled,
                                                   preview: true)
                                    .frame(height: 48)
                            }
                            Text(s.label)
                                .font(.system(size: 10.5, weight: on ? .medium : .regular))
                                .foregroundStyle(on ? Theme.text : Theme.textDim)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(s.blurb)
                    .accessibilityLabel("Motion style: \(s.label)")
                    .accessibilityHint(s.blurb)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }

            note(style.blurb)

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
                note(MotionLibrary.describe(source)
                     + " Loops live in \(MotionLibrary.userFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
                     + ", named after the style — ocean.mp4, clouds.mov. The switch on the right "
                     + "goes back to the drawn version without deleting anything.")
            }
        }
    }

    private func note(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }
}
