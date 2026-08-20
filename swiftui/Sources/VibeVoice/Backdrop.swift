import SwiftUI
import AppKit

/// The scene behind the orb.
///
/// The place presets are painted, not photographed — layered gradients tuned to the light
/// of somewhere rather than a picture of it. That keeps the app a couple of megabytes,
/// ships nothing with a licence attached, and scales to any window size without going
/// soft. If you want the real thing, `custom` takes your own photo.
enum Backdrop: String, Codable, CaseIterable, Identifiable {
    case midnight, paper, bali, capeTown, sanFrancisco, europe, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .midnight:      return "Midnight"
        case .paper:         return "Paper"
        case .bali:          return "Bali"
        case .capeTown:      return "Cape Town"
        case .sanFrancisco:  return "San Francisco"
        case .europe:        return "Alps"
        case .custom:        return "Your photo"
        }
    }

    var blurb: String {
        switch self {
        case .midnight:     return "Near-black. The default."
        case .paper:        return "Warm off-white."
        case .bali:         return "Teal water into a gold sunset."
        case .capeTown:     return "Indigo dusk behind the mountain."
        case .sanFrancisco: return "Fog over the bay, peach at the edges."
        case .europe:       return "Cold blue and snow light."
        case .custom:       return "Any image on this Mac."
        }
    }

    /// Colours are given as hex so the palettes read as palettes, and stay easy to tune.
    var colors: [Color] {
        switch self {
        case .midnight:     return [hex(0x0B0B0F), hex(0x131722), hex(0x0A0A0E)]
        case .paper:        return [hex(0xFBF7F0), hex(0xF3ECE1), hex(0xEDE4D6)]
        case .bali:         return [hex(0x0B3B49), hex(0x14707F), hex(0xE9A05C), hex(0xF2C078)]
        case .capeTown:     return [hex(0x161A3A), hex(0x3B2A5A), hex(0xC85C4A), hex(0xF0A05A)]
        case .sanFrancisco: return [hex(0x2B3A4A), hex(0x6E8598), hex(0xC9A48C), hex(0xF0CDB4)]
        case .europe:       return [hex(0x0E2233), hex(0x2E5A78), hex(0x8FB8D0), hex(0xE8F1F6)]
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
    /// Drifts the light slightly with the voice, so the scene feels alive without
    /// competing with the orb for attention.
    var energy: Double = 0

    var body: some View {
        ZStack {
            if backdrop == .custom, let img = loadImage() {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            } else {
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
