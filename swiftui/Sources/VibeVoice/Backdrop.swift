import SwiftUI
import AppKit

/// The scene behind the orb.
///
/// The place presets are painted, not photographed — layered gradients tuned to the light
/// of somewhere rather than a picture of it. That keeps the app a couple of megabytes,
/// ships nothing with a licence attached, and scales to any window size without going
/// soft. If you want the real thing, `custom` takes your own photo.
enum Backdrop: String, Codable, CaseIterable, Identifiable {
    case midnight, paper, bali, capeTown, sanFrancisco, alps, tokyo, sahara, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .midnight:      return "Midnight"
        case .paper:         return "Paper"
        case .bali:          return "Bali"
        case .capeTown:      return "Cape Town"
        case .sanFrancisco:  return "San Francisco"
        case .alps:          return "Alps"
        case .tokyo:         return "Tokyo"
        case .sahara:        return "Sahara"
        case .custom:        return "Your photo"
        }
    }

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
        case .custom:       return [hex(0x0B0B0F), hex(0x131722)]
        }
    }

    /// Whether UI text should sit on a dark or light ground. Scenic presets are dark
    /// enough at the top that the existing light-on-dark type keeps working.
    var prefersDarkText: Bool { self == .paper }

    /// How strongly to veil the scene behind the reading area. A photograph needs more
    /// help than a gradient before small type is comfortable on it.
    var scrim: Double {
        switch self {
        case .midnight, .paper: return 0.0
        case .custom:           return 0.55
        default:                return 0.28
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
            } else if backdrop == .custom, let img = loadImage() {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
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

            if backdrop.scrim > 0 {
                LinearGradient(
                    colors: [Color.black.opacity(backdrop.scrim * 0.85),
                             Color.black.opacity(backdrop.scrim * 1.15)],
                    startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    private func loadImage() -> NSImage? {
        guard !imagePath.isEmpty else { return nil }
        return NSImage(contentsOfFile: (imagePath as NSString).expandingTildeInPath)
    }
}

enum BackdropPicker {
    /// Asks for an image file. Returns nil if the user cancels.
    @MainActor
    static func chooseImage() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use as backdrop"
        panel.message = "Pick a photo for the background"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
