import SwiftUI
import AppKit
import FlowStateCore

/// How a `Backdrop` is drawn.
///
/// The cases, their names and which kind each one is live in `FlowStateCore` — see
/// `LookBackdrop.swift` — so the Look pane's two galleries are stated somewhere that can
/// be tested without a window. What is left here is the half that needs SwiftUI: the
/// palettes, the painted places and the veil that keeps text readable on top of them.
///
/// The place presets are painted, not photographed — layered gradients tuned to the light
/// of somewhere rather than a picture of it. That keeps the app a couple of megabytes,
/// ships nothing with a licence attached, and scales to any window size without going
/// soft. If you want the real thing, `custom` takes your own photo.
extension Backdrop {

    var blurb: String {
        switch self {
        case .midnight:     return "Near-black. The default."
        case .paper:        return "Warm off-white."
        case .bali:         return Place.bali.blurb
        case .capeTown:     return Place.capeTown.blurb
        case .sanFrancisco: return Place.sanFrancisco.blurb
        case .alps:         return Place.alps.blurb
        case .tokyo:        return Place.tokyo.blurb
        case .sahara:       return Place.sahara.blurb
        case .motion:       return "Something flowing, rather than somewhere."
        case .custom:       return "Any image on this Mac."
        }
    }

    /// The painted place behind this backdrop, if it is one.
    var place: Place? {
        switch self {
        case .bali:         return .bali
        case .capeTown:     return .capeTown
        case .sanFrancisco: return .sanFrancisco
        case .alps:         return .alps
        case .tokyo:        return .tokyo
        case .sahara:       return .sahara
        default:            return nil
        }
    }

    /// Colours are given as hex so the palettes read as palettes, and stay easy to tune.
    var colors: [Color] {
        switch self {
        case .midnight:     return [hex(0x0B0B0F), hex(0x131722), hex(0x0A0A0E)]
        case .paper:        return [hex(0xFBF7F0), hex(0xF3ECE1), hex(0xEDE4D6)]
        case .bali, .capeTown, .sanFrancisco, .alps, .tokyo, .sahara:
            return place?.spec(Daylight.now()).sky ?? [hex(0x0B0B0F)]
        case .motion:       return [hex(0x0A1420), hex(0x1E3A4E), hex(0x2E6E7E)]
        case .custom:       return [hex(0x0B0B0F), hex(0x131722)]
        }
    }

    /// How strongly to veil the scene behind the reading area.
    ///
    /// This is the fix for the obvious bug in the first version: at dusk a light veil was
    /// plenty, but a midday sky is bright, and light text on bright sky is unreadable
    /// however the chrome is themed. So the veil tracks the hour — heavy at noon, barely
    /// there at night — which keeps contrast constant while letting the scene keep its
    /// colour. A photograph gets more than a painting, because it has detail to fight.
    func scrim(_ t: Daylight) -> Double {
        switch self {
        case .midnight, .paper: return 0.0
        // The moving styles are all built dark, and unlike a sky they do not brighten at
        // noon — so their veil is a constant, and a light one.
        case .motion: return 0.30
        case .custom:
            switch t {
            case .day:   return 0.68
            case .dawn:  return 0.60
            case .dusk:  return 0.56
            case .night: return 0.50
            }
        default:
            switch t {
            case .day:   return 0.52
            case .dawn:  return 0.38
            case .dusk:  return 0.30
            case .night: return 0.20
            }
        }
    }

    private func hex(_ v: UInt32) -> Color {
        Color(.sRGB,
              red: Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255,
              opacity: 1)
    }
}

/// Paints the chosen backdrop, with a scrim so text stays readable on top of it.
struct BackdropView: View {
    let backdrop: Backdrop
    let imagePath: String
    /// Which light to paint the place in.
    var daylight: Daylight = .now()
    /// Slow drift for shimmer and twinkle. Driven internally so callers stay simple.
    /// Drifts the light slightly with the voice, so the scene feels alive without
    /// competing with the orb for attention.
    var energy: Double = 0
    /// Which photo to show when `imagePath` points at a folder.
    var rotationIndex: Int = 0
    /// Which moving style to draw when the backdrop is `.motion`.
    var motionStyle: MotionStyle = .fluid
    var motionIntensity: Double = 0.6
    var motionAssets: Bool = true

    var body: some View {
        ZStack {
            if let place = backdrop.place {
                // 8 fps is plenty for water and starlight, and costs a fraction of what
                // redrawing on every display refresh would.
                TimelineView(.periodic(from: .now, by: 1.0 / 8.0)) { tl in
                    SceneView(spec: place.spec(daylight),
                              energy: energy,
                              phase: tl.date.timeIntervalSinceReferenceDate)
                }
            } else if backdrop == .motion {
                // No TimelineView here: this one runs its own clock, because how often it
                // is allowed to redraw depends on which of three renderers it landed on.
                MotionBackdropView(style: motionStyle,
                                   intensity: motionIntensity,
                                   energy: energy,
                                   assetsEnabled: motionAssets)
            } else if backdrop == .custom {
                // Ticks once a second so a rotating folder actually advances; the decoded
                // image is cached, so a tick that changes nothing costs nothing.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if let img = loadImage() {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipped()
                    } else {
                        LinearGradient(colors: backdrop.colors,
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
            } else if backdrop != .custom {
                LinearGradient(colors: backdrop.colors,
                               startPoint: .topLeading, endPoint: .bottomTrailing)

                // A soft warm light that breathes with the conversation.
                RadialGradient(colors: [Color.white.opacity(0.10 + energy * 0.10), .clear],
                               center: .init(x: 0.7, y: 0.22),
                               startRadius: 0, endRadius: 700)
                    .blendMode(.plusLighter)
                    .animation(.easeInOut(duration: 0.9), value: energy)
            }

            let scrim = backdrop.scrim(daylight)
            if scrim > 0 {
                // Slightly heavier at the top and bottom, where the header, the transcript
                // and the buttons live. The middle, where the orb is, stays clearest.
                LinearGradient(
                    stops: [.init(color: .black.opacity(scrim * 1.25), location: 0.00),
                            .init(color: .black.opacity(scrim * 0.70), location: 0.35),
                            .init(color: .black.opacity(scrim * 0.70), location: 0.62),
                            .init(color: .black.opacity(scrim * 1.30), location: 1.00)],
                    startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    private func loadImage() -> NSImage? {
        PhotoBackdrop.image(for: imagePath, rotationIndex: rotationIndex)
    }
}

enum BackdropPicker {
    /// Asks for a photo, or a folder of them.
    ///
    /// A folder is the interesting case: point this at your Cape Town album and Flow
    /// rotates through it. Your own photographs of a place beat any stock image of it,
    /// and they are the only ones anybody has the right to ship.
    @MainActor
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Use as backdrop"
        panel.message = "Pick a photo, or a folder of photos to rotate through"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

/// Resolves a backdrop path that may be a single image or a folder of them.
enum PhotoBackdrop {
    private static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "webp"]

    /// Every usable image at `path`, sorted so the order is stable between launches.
    static func images(at path: String) -> [String] {
        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return [expanded] }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: expanded)) ?? []
        return names
            .filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
            .map { expanded + "/" + $0 }
    }

    static func isFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    /// Decoding a full-resolution photo on every redraw would be absurd, and this view
    /// redraws whenever the voice level moves — so exactly one decoded image is kept.
    private static var cache: (path: String, image: NSImage)?

    static func image(for path: String, rotationIndex: Int) -> NSImage? {
        let all = images(at: path)
        guard !all.isEmpty else { return nil }
        let chosen = all[((rotationIndex % all.count) + all.count) % all.count]
        if let c = cache, c.path == chosen { return c.image }
        guard let img = NSImage(contentsOfFile: chosen) else { return nil }
        cache = (chosen, img)
        return img
    }
}
