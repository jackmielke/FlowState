import SwiftUI

enum OrbMode {
    case idle, listening, speaking, connecting, error

    var palette: [Color] {
        switch self {
        case .idle:       return [Color(red: 0.52, green: 0.50, blue: 0.55),
                                  Color(red: 0.30, green: 0.28, blue: 0.34),
                                  Color(red: 0.38, green: 0.28, blue: 0.22)]
        case .listening:  return [Theme.accentSoft, Theme.accent, Theme.accentDeep]
        case .speaking:   return [Theme.voice, Theme.voiceDeep, Color(red: 0.30, green: 0.55, blue: 0.95)]
        case .connecting: return [Color(red: 0.65, green: 0.68, blue: 0.78), Color(red: 0.36, green: 0.40, blue: 0.52)]
        case .error:      return [Theme.bad, Color(red: 0.55, green: 0.16, blue: 0.20)]
        }
    }
}

/// The centerpiece. Every radius here is driven by real RMS from the audio
/// buffers — nothing is on a decorative timer except the slow rotation.
struct VoiceOrb: View {
    var mode: OrbMode
    /// 0…1, already smoothed. Real amplitude.
    var level: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                draw(ctx: &ctx, size: size, t: t)
            }
            .allowsHitTesting(false)
        }
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let unit = min(size.width, size.height) / 2
        // Perceptual boost — raw RMS is tiny for speech.
        let lv = CGFloat(min(1, pow(Double(level) * 6.0, 0.75)))
        let colors = mode.palette
        let base = unit * (0.40 + 0.10 * lv)
        let breathe = 1 + 0.025 * CGFloat(sin(t * 1.1))

        // 1 — ambient bloom
        let bloomR = unit * (0.95 + 0.35 * lv)
        ctx.fill(
            Path(ellipseIn: CGRect(x: c.x - bloomR, y: c.y - bloomR, width: bloomR * 2, height: bloomR * 2)),
            with: .radialGradient(
                Gradient(colors: [colors[0].opacity(0.34 + 0.30 * lv), colors[min(1, colors.count - 1)].opacity(0.08), .clear]),
                center: c, startRadius: 0, endRadius: bloomR))

        // 2 — soft harmonic blobs, additively blended
        var layer = ctx
        layer.addFilter(.blur(radius: unit * 0.09))
        layer.blendMode = .plusLighter
        let specs: [(lobes: Int, speed: Double, amp: CGFloat, scale: CGFloat, ci: Int)] = [
            (3, 0.31, 0.16, 1.10, 0),
            (5, -0.24, 0.12, 0.95, min(1, colors.count - 1)),
            (4, 0.44, 0.10, 0.82, colors.count - 1)
        ]
        for s in specs {
            let p = blob(center: c,
                         radius: base * s.scale * breathe,
                         lobes: s.lobes,
                         amp: s.amp * (0.30 + 1.7 * lv),
                         phase: t * s.speed)
            layer.fill(p, with: .radialGradient(
                Gradient(colors: [colors[s.ci].opacity(0.55), colors[s.ci].opacity(0.05)]),
                center: c, startRadius: base * 0.15, endRadius: base * s.scale * 1.25))
        }

        // 3 — crisp contour
        var edge = ctx
        edge.blendMode = .plusLighter
        let ring = blob(center: c, radius: base * 1.16 * breathe, lobes: 3,
                        amp: 0.10 * (0.30 + 1.7 * lv), phase: t * 0.31)
        edge.stroke(ring, with: .linearGradient(
            Gradient(colors: [colors[0].opacity(0.85), colors[colors.count - 1].opacity(0.15)]),
            startPoint: CGPoint(x: c.x - base, y: c.y - base),
            endPoint: CGPoint(x: c.x + base, y: c.y + base)),
            lineWidth: 1.2 + 1.6 * lv)

        // 3b — quiet orbit rings so the idle state still has architecture
        for (i, k) in [1.52, 1.78, 1.97].enumerated() {
            let rr = unit * CGFloat(k) * 0.5
            var ring2 = Path()
            ring2.addEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
            edge.stroke(ring2,
                        with: .color(colors[i % colors.count].opacity(0.055 + 0.05 * lv)),
                        lineWidth: 0.7)
        }

        // 4 — reactive halo ring, radius is pure amplitude
        if lv > 0.02 {
            let hr = base * (1.32 + 0.55 * lv)
            edge.stroke(Path(ellipseIn: CGRect(x: c.x - hr, y: c.y - hr, width: hr * 2, height: hr * 2)),
                        with: .color(colors[0].opacity(0.10 + 0.35 * lv)),
                        lineWidth: 0.8)
        }

        // 5 — core
        let coreR = base * (0.44 + 0.16 * lv)
        var core = ctx
        core.blendMode = .plusLighter
        core.fill(
            Path(ellipseIn: CGRect(x: c.x - coreR, y: c.y - coreR, width: coreR * 2, height: coreR * 2)),
            with: .radialGradient(
                Gradient(colors: [.white.opacity(0.72 + 0.24 * lv), colors[0].opacity(0.75), colors[colors.count - 1].opacity(0.0)]),
                center: CGPoint(x: c.x - coreR * 0.18, y: c.y - coreR * 0.22),
                startRadius: 0, endRadius: coreR * 1.5))

        // 6 — orbiting sparks
        var sparks = ctx
        sparks.blendMode = .plusLighter
        let n = 22
        for i in 0..<n {
            let f = Double(i) / Double(n)
            let ang = f * .pi * 2 + t * (0.18 + 0.22 * Double(lv)) * (i % 2 == 0 ? 1 : -1.4)
            let rr = base * (1.30 + 0.30 * CGFloat(sin(f * 12 + t * 0.9))) + base * 0.55 * lv
            let p = CGPoint(x: c.x + cos(ang) * rr, y: c.y + sin(ang) * rr)
            let d = 1.0 + 2.2 * CGFloat(lv) * CGFloat(abs(sin(f * 7 + t)))
            sparks.fill(Path(ellipseIn: CGRect(x: p.x - d, y: p.y - d, width: d * 2, height: d * 2)),
                        with: .color(colors[i % colors.count].opacity(0.18 + 0.5 * lv)))
        }
    }

    /// Closed path whose radius is modulated by two harmonics.
    private func blob(center: CGPoint, radius: CGFloat, lobes: Int, amp: CGFloat, phase: Double) -> Path {
        var p = Path()
        let steps = 140
        for i in 0...steps {
            let th = Double(i) / Double(steps) * .pi * 2
            let m = 1
                + Double(amp) * sin(Double(lobes) * th + phase * 2.0)
                + Double(amp) * 0.45 * sin(Double(lobes + 2) * th - phase * 1.3)
            let r = radius * CGFloat(m)
            let pt = CGPoint(x: center.x + cos(th) * r, y: center.y + sin(th) * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// Real-amplitude meter. Every bar is one sampled RMS value off the audio thread —
/// it scrolls right to left as real audio arrives.
struct LevelMeter: View {
    var history: [Float]
    var tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(history.enumerated()), id: \.offset) { idx, v in
                let lv = min(1.0, pow(Double(v) * 6.5, 0.7))
                // newest samples on the right read brightest
                let recency = 0.35 + 0.65 * (Double(idx) / Double(max(history.count - 1, 1)))
                Capsule()
                    .fill(lv > 0.05 ? tint.opacity(0.25 + 0.7 * lv * recency)
                                    : Theme.textFaint.opacity(0.18 * recency))
                    .frame(width: 3, height: max(3, CGFloat(3 + lv * 30)))
            }
        }
        .frame(height: 34)
        .animation(.linear(duration: 0.045), value: history)
    }
}
