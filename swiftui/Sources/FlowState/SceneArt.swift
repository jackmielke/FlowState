import SwiftUI

/// Painted places.
///
/// Every scene here is drawn, not photographed: a sky, a light source, silhouetted
/// ridgelines and sometimes water, composed from a handful of numbers. That means no
/// licences, no megabytes, no blurring when the window is resized to 6K — and the one
/// thing a photograph can never do, which is change with the hour. Cape Town at 9pm
/// looks like Cape Town at 9pm.
///
/// The ridgelines are seeded value noise, so a given place is always the same place.

// MARK: - Time of day

enum Daylight: String, CaseIterable {
    case dawn, day, dusk, night

    /// Local wall-clock hour → the light you'd actually be standing in.
    static func now(_ date: Date = Date(), calendar: Foundation.Calendar = .current) -> Daylight {
        switch calendar.component(.hour, from: date) {
        case 5..<8:   return .dawn
        case 8..<17:  return .day
        case 17..<20: return .dusk
        default:      return .night
        }
    }

    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

// MARK: - Scene description

struct Ridge {
    var color: Color
    /// 0 = top of the window, 1 = bottom.
    var baseline: Double
    var amplitude: Double
    /// Higher = more jagged. Alps are rough, Bali is not.
    var roughness: Double
    var seed: UInt64
}

struct SceneSpec {
    var sky: [Color]
    var light: Color?
    /// Unit position of the sun or moon.
    var lightAt: CGPoint = .init(x: 0.72, y: 0.30)
    var lightRadius: Double = 0.10
    var ridges: [Ridge] = []
    /// Height of the reflective band, 0 = no water.
    var water: Double = 0
    var waterTint: Color = .white
    var stars: Double = 0
    var haze: Color?
}

// MARK: - Places

enum Place: String, CaseIterable, Codable, Identifiable {
    case bali, capeTown, sanFrancisco, alps, tokyo, sahara

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bali:          return "Bali"
        case .capeTown:      return "Cape Town"
        case .sanFrancisco:  return "San Francisco"
        case .alps:          return "Alps"
        case .tokyo:         return "Tokyo"
        case .sahara:        return "Sahara"
        }
    }

    var blurb: String {
        switch self {
        case .bali:         return "Rice terraces, palms, water going gold."
        case .capeTown:     return "Table Mountain flat against the sky."
        case .sanFrancisco: return "Fog rolling over the headlands."
        case .alps:         return "Hard peaks and thin cold air."
        case .tokyo:        return "Neon haze, city glow under low cloud."
        case .sahara:       return "Dune after dune, nothing else."
        }
    }

    func spec(_ t: Daylight) -> SceneSpec {
        switch self {
        case .bali:          return Self.bali(t)
        case .capeTown:      return Self.capeTown(t)
        case .sanFrancisco:  return Self.sanFrancisco(t)
        case .alps:          return Self.alps(t)
        case .tokyo:         return Self.tokyo(t)
        case .sahara:        return Self.sahara(t)
        }
    }

    // Each place is the same landform in four different lights.

    private static func bali(_ t: Daylight) -> SceneSpec {
        let sky: [Color]
        let light: Color
        switch t {
        case .dawn:  sky = [c(0x1B3A4B), c(0x3E6B7A), c(0xE8A87C), c(0xF6D7A7)]; light = c(0xFFE0B0)
        case .day:   sky = [c(0x1E7A9E), c(0x4FB3C9), c(0x9FDCE3), c(0xE8F6F2)]; light = c(0xFFF6D8)
        case .dusk:  sky = [c(0x14283F), c(0x5B3A63), c(0xE0714F), c(0xF2B265)]; light = c(0xFFB07A)
        case .night: sky = [c(0x050B18), c(0x0B1B33), c(0x14314F), c(0x1E4A63)]; light = c(0xD8E6FF)
        }
        return SceneSpec(
            sky: sky, light: light,
            lightAt: .init(x: 0.74, y: t == .night ? 0.18 : 0.34),
            lightRadius: t == .night ? 0.045 : 0.085,
            ridges: [
                Ridge(color: c(0x0C2A33).opacity(0.55), baseline: 0.62, amplitude: 0.05, roughness: 0.4, seed: 11),
                Ridge(color: c(0x07202A).opacity(0.85), baseline: 0.70, amplitude: 0.035, roughness: 0.3, seed: 12),
            ],
            water: 0.30, waterTint: light,
            stars: t == .night ? 0.9 : 0,
            haze: t == .day ? .white.opacity(0.06) : nil)
    }

    private static func capeTown(_ t: Daylight) -> SceneSpec {
        let sky: [Color]
        let light: Color
        switch t {
        case .dawn:  sky = [c(0x232A52), c(0x4A457A), c(0xD98A6A), c(0xF3C08A)]; light = c(0xFFD9A8)
        case .day:   sky = [c(0x1D5C8C), c(0x4E8FBF), c(0xA9CFE3), c(0xE6F0F5)]; light = c(0xFFFBE8)
        case .dusk:  sky = [c(0x141838), c(0x3E2A56), c(0xC1544A), c(0xEE9A5A)]; light = c(0xFFC07A)
        case .night: sky = [c(0x04060F), c(0x0A1024), c(0x121C3A), c(0x1B2A4A)]; light = c(0xE2ECFF)
        }
        return SceneSpec(
            sky: sky, light: light,
            lightAt: .init(x: 0.24, y: t == .night ? 0.16 : 0.32),
            lightRadius: t == .night ? 0.04 : 0.08,
            ridges: [
                Ridge(color: c(0x243055).opacity(0.45), baseline: 0.52, amplitude: 0.14, roughness: 0.75, seed: 20),
                // The flat top is the whole point of the silhouette.
                Ridge(color: c(0x1A2036).opacity(0.72), baseline: 0.60, amplitude: 0.16, roughness: 0.12, seed: 21),
                Ridge(color: c(0x0B0F1E).opacity(0.95), baseline: 0.70, amplitude: 0.09, roughness: 0.35, seed: 22),
            ],
            water: 0.22, waterTint: light,
            stars: t == .night ? 1.0 : 0,
            haze: nil)
    }

    private static func sanFrancisco(_ t: Daylight) -> SceneSpec {
        let sky: [Color]
        let light: Color
        switch t {
        case .dawn:  sky = [c(0x3A4757), c(0x6E7C8C), c(0xC9A08A), c(0xEBD3BE)]; light = c(0xFFE3C8)
        case .day:   sky = [c(0x5B7186), c(0x93A9B8), c(0xC9D6DC), c(0xEFF3F4)]; light = c(0xFFFFFF)
        case .dusk:  sky = [c(0x2A3242), c(0x5A5468), c(0xB07A6E), c(0xE0A98C)]; light = c(0xFFC9A0)
        case .night: sky = [c(0x070A12), c(0x101726), c(0x1A2434), c(0x243244)]; light = c(0xCFE0F5)
        }
        return SceneSpec(
            sky: sky, light: light,
            lightAt: .init(x: 0.68, y: 0.28),
            lightRadius: t == .day ? 0.14 : 0.07,
            ridges: [
                Ridge(color: c(0x2C3846).opacity(0.35), baseline: 0.60, amplitude: 0.06, roughness: 0.5, seed: 31),
                Ridge(color: c(0x151C26).opacity(0.75), baseline: 0.69, amplitude: 0.045, roughness: 0.45, seed: 32),
            ],
            water: 0.24, waterTint: light,
            stars: t == .night ? 0.5 : 0,
            // The fog is the landmark here, more than any bridge.
            haze: .white.opacity(t == .night ? 0.10 : 0.22))
    }

    private static func alps(_ t: Daylight) -> SceneSpec {
        let sky: [Color]
        let light: Color
        switch t {
        case .dawn:  sky = [c(0x2B3F5C), c(0x5E7392), c(0xD5A9A0), c(0xF0D6C6)]; light = c(0xFFE6D2)
        case .day:   sky = [c(0x1C5C93), c(0x4E90C4), c(0xA8CFE8), c(0xEAF4FA)]; light = c(0xFFFFFF)
        case .dusk:  sky = [c(0x161E3A), c(0x3C3A66), c(0x9A5F76), c(0xD79A8C)]; light = c(0xFFD0BC)
        case .night: sky = [c(0x03060E), c(0x081020), c(0x101B30), c(0x17263F)]; light = c(0xEAF2FF)
        }
        return SceneSpec(
            sky: sky, light: light,
            lightAt: .init(x: 0.80, y: t == .night ? 0.14 : 0.26),
            lightRadius: t == .night ? 0.035 : 0.07,
            ridges: [
                Ridge(color: c(0x8FB3CC).opacity(t == .night ? 0.12 : 0.30), baseline: 0.52, amplitude: 0.13, roughness: 0.95, seed: 41),
                Ridge(color: c(0x2A3B52).opacity(0.70), baseline: 0.62, amplitude: 0.10, roughness: 0.85, seed: 42),
                Ridge(color: c(0x0D1522).opacity(0.95), baseline: 0.73, amplitude: 0.07, roughness: 0.7, seed: 43),
            ],
            water: 0, stars: t == .night ? 1.0 : 0,
            haze: t == .day ? .white.opacity(0.08) : nil)
    }

    private static func tokyo(_ t: Daylight) -> SceneSpec {
        let sky: [Color]
        let light: Color
        switch t {
        case .dawn:  sky = [c(0x2A2740), c(0x54486B), c(0xC77E92), c(0xEEBFC4)]; light = c(0xFFD5DE)
        case .day:   sky = [c(0x6C7B93), c(0x9AA7BA), c(0xC5CEDA), c(0xE9EDF2)]; light = c(0xFFFFFF)
        case .dusk:  sky = [c(0x18132E), c(0x3B2050), c(0x8C2F63), c(0xD9556E)]; light = c(0xFF9BB0)
        case .night: sky = [c(0x08060F), c(0x140C22), c(0x24123A), c(0x3A1B4E)]; light = c(0xFF7FB0)
        }
        return SceneSpec(
            sky: sky, light: light,
            lightAt: .init(x: 0.50, y: 0.74),          // glow rises from the city, not the sky
            lightRadius: 0.22,
            ridges: [
                Ridge(color: c(0x120C1E).opacity(0.85), baseline: 0.72, amplitude: 0.03, roughness: 1.0, seed: 51),
            ],
            water: 0, stars: t == .night ? 0.25 : 0,
            haze: .purple.opacity(t == .night ? 0.10 : 0.05))
    }

    private static func sahara(_ t: Daylight) -> SceneSpec {
        let sky: [Color]
        let light: Color
        switch t {
        case .dawn:  sky = [c(0x3B3A5C), c(0x7B6480), c(0xE0A277), c(0xF6D9A8)]; light = c(0xFFE7BE)
        case .day:   sky = [c(0x2E86B8), c(0x74B4D4), c(0xD8CFA8), c(0xF0E2BC)]; light = c(0xFFF8DC)
        case .dusk:  sky = [c(0x1E1B34), c(0x59304F), c(0xC85C3C), c(0xF0A35C)]; light = c(0xFFBE7A)
        case .night: sky = [c(0x04040C), c(0x0A0A1A), c(0x14142C), c(0x1E1E3C)]; light = c(0xF0F0FF)
        }
        return SceneSpec(
            sky: sky, light: light,
            lightAt: .init(x: 0.30, y: t == .night ? 0.20 : 0.44),
            lightRadius: t == .night ? 0.04 : 0.10,
            ridges: [
                Ridge(color: c(0xC79A63).opacity(t == .night ? 0.18 : 0.55), baseline: 0.66, amplitude: 0.05, roughness: 0.2, seed: 61),
                Ridge(color: c(0x7A5636).opacity(t == .night ? 0.35 : 0.75), baseline: 0.74, amplitude: 0.045, roughness: 0.18, seed: 62),
                Ridge(color: c(0x2E1E12).opacity(0.9), baseline: 0.84, amplitude: 0.03, roughness: 0.15, seed: 63),
            ],
            water: 0, stars: t == .night ? 1.0 : 0,
            haze: t == .day ? c(0xFFE9B0).opacity(0.10) : nil)
    }

    private static func c(_ v: UInt32) -> Color {
        Color(.sRGB,
              red: Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255,
              opacity: 1)
    }
}

// MARK: - Renderer

struct SceneView: View {
    let spec: SceneSpec
    /// Voice amplitude, 0…1. Moves the light a little; never enough to distract.
    var energy: Double = 0
    /// Slow continuous drift so the scene is alive when nothing is happening.
    var phase: Double = 0

    var body: some View {
        Canvas(rendersAsynchronously: true) { ctx, size in
            let w = size.width, h = size.height

            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(.init(colors: spec.sky),
                                           startPoint: .zero, endPoint: .init(x: 0, y: h)))

            if spec.stars > 0 { drawStars(&ctx, size) }

            if let light = spec.light {
                let lx = w * spec.lightAt.x
                let ly = h * spec.lightAt.y - CGFloat(energy * 8)
                let r = max(w, h) * spec.lightRadius * (1 + energy * 0.18)
                // Glow first, then the disc, so the disc keeps a hard edge.
                // Three nested falloffs: wide atmospheric bloom, tighter halo, then a
                // core that still fades at its rim. Real light has no outline.
                ctx.fill(Path(ellipseIn: CGRect(x: lx - r * 4.0, y: ly - r * 4.0,
                                                width: r * 8.0, height: r * 8.0)),
                         with: .radialGradient(.init(colors: [light.opacity(0.22), .clear]),
                                               center: .init(x: lx, y: ly),
                                               startRadius: 0, endRadius: r * 4.0))
                ctx.fill(Path(ellipseIn: CGRect(x: lx - r * 1.3, y: ly - r * 1.3,
                                                width: r * 2.6, height: r * 2.6)),
                         with: .radialGradient(.init(colors: [light.opacity(0.45), .clear]),
                                               center: .init(x: lx, y: ly),
                                               startRadius: 0, endRadius: r * 1.3))
                ctx.fill(Path(ellipseIn: CGRect(x: lx - r * 0.34, y: ly - r * 0.34,
                                                width: r * 0.68, height: r * 0.68)),
                         with: .radialGradient(
                            .init(stops: [.init(color: light.opacity(0.95), location: 0),
                                          .init(color: light.opacity(0.85), location: 0.55),
                                          .init(color: light.opacity(0.0), location: 1)]),
                            center: .init(x: lx, y: ly), startRadius: 0, endRadius: r * 0.34))
            }

            if spec.water > 0, let light = spec.light { drawWater(&ctx, size, light) }

            for ridge in spec.ridges { drawRidge(&ctx, size, ridge) }

            if let haze = spec.haze {
                ctx.fill(Path(CGRect(x: 0, y: h * 0.42, width: w, height: h * 0.58)),
                         with: .linearGradient(.init(colors: [.clear, haze, haze]),
                                               startPoint: .init(x: 0, y: h * 0.42),
                                               endPoint: .init(x: 0, y: h)))
            }
        }
        .drawingGroup()
    }

    // MARK: draw helpers

    private func drawStars(_ ctx: inout GraphicsContext, _ size: CGSize) {
        var rng = Seeded(9_1731)
        let count = Int(spec.stars * 150)
        for i in 0..<count {
            let x = rng.next01() * size.width
            let y = rng.next01() * size.height * 0.62
            let base = rng.next01()
            // Twinkle is deterministic per star, so it shimmers instead of flickering.
            let tw = 0.45 + 0.55 * abs(sin(phase * 1.4 + Double(i) * 0.7))
            let r = 0.5 + base * 1.3
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                     with: .color(.white.opacity(0.20 + 0.55 * base * tw)))
        }
    }

    private func drawWater(_ ctx: inout GraphicsContext, _ size: CGSize, _ light: Color) {
        let top = size.height * (1 - spec.water)
        let rect = CGRect(x: 0, y: top, width: size.width, height: size.height - top)
        ctx.fill(Path(rect), with: .linearGradient(
            .init(colors: [light.opacity(0.20), light.opacity(0.04), .black.opacity(0.30)]),
            startPoint: .init(x: 0, y: top), endPoint: .init(x: 0, y: size.height)))

        // A sun path on the water, widening as it comes toward you.
        let cx = size.width * spec.lightAt.x
        var y = top
        var i = 0
        while y < size.height {
            let spread = (y - top) / max(1, size.height - top)
            let wdt = 10 + spread * 120 + sin(phase * 0.9 + Double(i) * 0.55) * 12
            let hgt = 1.2 + spread * 2.0
            let a = (1 - spread) * 0.34 * (0.55 + 0.45 * abs(sin(phase + Double(i) * 0.4)))
            ctx.fill(Path(ellipseIn: CGRect(x: cx - wdt / 2, y: y, width: wdt, height: hgt)),
                     with: .color(light.opacity(a)))
            y += 7 + spread * 9
            i += 1
        }
    }

    private var rimLight: Color? {
        guard let l = spec.light else { return nil }
        return l.opacity(0.16)
    }

    private func drawRidge(_ ctx: inout GraphicsContext, _ size: CGSize, _ r: Ridge) {
        var path = Path()
        let base = size.height * r.baseline
        let amp = size.height * r.amplitude
        path.move(to: .init(x: 0, y: size.height))

        var noise = ValueNoise(seed: r.seed)
        let steps = 96
        for s in 0...steps {
            let u = Double(s) / Double(steps)
            // Two octaves is enough for a horizon: one for the shape, one for the teeth.
            let n = noise.at(u * (2 + r.roughness * 6)) * 0.7
                  + noise.at(u * (7 + r.roughness * 22)) * 0.3 * r.roughness
            path.addLine(to: .init(x: u * size.width, y: base - amp * n))
        }
        path.addLine(to: .init(x: size.width, y: size.height))
        path.closeSubpath()
        ctx.fill(path, with: .color(r.color))

        // A hairline of sky-light along the crest. Without it a silhouette on a gradient
        // reads as a flat band rather than a ridge standing in front of something.
        if let rim = rimLight {
            ctx.stroke(path, with: .color(rim), lineWidth: 1.1)
        }
    }
}

// MARK: - Deterministic noise

/// Tiny LCG. Seeded so a place looks the same every launch.
private struct Seeded {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
    mutating func next01() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// Smoothed 1-D value noise — the ridgelines.
private struct ValueNoise {
    let seed: UInt64
    private var cache: [Int: Double] = [:]

    init(seed: UInt64) { self.seed = seed }

    private mutating func rand(_ i: Int) -> Double {
        if let v = cache[i] { return v }
        var s = Seeded(seed &* 7919 &+ UInt64(bitPattern: Int64(i)) &* 104_729)
        let v = s.next01()
        cache[i] = v
        return v
    }

    mutating func at(_ x: Double) -> Double {
        let i = Int(floor(x))
        let f = x - Double(i)
        let a = rand(i), b = rand(i + 1)
        let t = f * f * (3 - 2 * f)          // smoothstep
        return a + (b - a) * t
    }
}
