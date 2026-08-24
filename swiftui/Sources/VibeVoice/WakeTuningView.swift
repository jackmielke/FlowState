import SwiftUI
import VibeVoiceCore

/// A place to find out why the wake trigger fired when it should not have.
///
/// A wake word is tuned by watching it be wrong. Without this, the only report available
/// is "it went off by accident" — which does not say whether the clap was too quiet, too
/// long, in the middle of a sentence, or whether it was the phrase and not the clap at
/// all. Each of those is a different number.
///
/// So every decision the detector makes is shown, including the ones that came to
/// nothing, with the reason it came to nothing. Tuning is then a matter of clapping,
/// reading, and moving one slider.
struct WakeTuningView: View {
    @ObservedObject var state: AppState

    /// Redrawn on a timer rather than by publishing every frame: the trace is written to
    /// from the audio thread twenty times a second per event, and driving SwiftUI from
    /// there would cost more than the detection.
    @State private var tick = 0
    private let clock = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Room level")
                    .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                Spacer()
                Text(db(state.wake.roomLevel))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textDim)
            }
            meter(state.wake.roomLevel)

            HStack {
                Text("Sensitivity").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                Spacer()
                Text(state.settings.clapSensitivity < 0.34 ? "Strict"
                     : state.settings.clapSensitivity < 0.67 ? "Balanced" : "Eager")
                    .font(.system(size: 11)).foregroundStyle(Theme.textDim)
            }
            Slider(value: Binding(
                get: { state.settings.clapSensitivity },
                set: { state.settings.clapSensitivity = $0
                       state.wake.clapSensitivity = Float($0) }), in: 0...1)

            Text("Strict wants a louder, sharper, better-matched pair, out of a quieter room. "
               + "Start here and only move up if it will not hear you.")
                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("What it heard").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                Spacer()
                Button("Clear") { state.wake.clearTrace(); state.wake.clearPhraseTrace() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(Theme.accent)
            }

            let rows = (state.wake.trace + state.wake.phraseTrace)
                .sorted { $0.at > $1.at }
                .prefix(14)

            if rows.isEmpty {
                Text("Nothing yet. Clap twice, or say the phrase — every decision shows up "
                   + "here, including the ones that came to nothing.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(rows) { row in
                        HStack(spacing: 6) {
                            Circle().fill(colour(row.kind)).frame(width: 6, height: 6)
                            Text(row.detail)
                                .font(.system(size: 11)).foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Spacer()
                            if row.peak > 0 {
                                Text(db(row.peak))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textFaint)
                            }
                        }
                    }
                }
            }
        }
        .onReceive(clock) { _ in tick &+= 1 }
        .id(tick)
    }

    private func colour(_ k: WakeTrace.Kind) -> Color {
        switch k {
        case .woke:     return Theme.good
        case .armed:    return Theme.accent
        case .rejected: return Theme.textFaint
        }
    }

    private func meter(_ level: Float) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill)
                Capsule().fill(Theme.accent)
                    // Log scale: the interesting range is 0.002 to 0.3, which is
                    // invisible on a linear bar.
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, (log10(max(level, 0.0005)) + 3.3) / 3.3))))
            }
        }
        .frame(height: 5)
    }

    private func db(_ v: Float) -> String {
        v <= 0.0005 ? "—" : String(format: "%.0f dB", 20 * log10(v))
    }
}
