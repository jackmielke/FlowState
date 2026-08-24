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
    @State private var countdown: Int?
    @State private var result: String?
    private let clock = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    /// Long enough for four or five claps without anybody feeling rushed.
    private let listenFor = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The calibration, first, because it is the thing to do rather than read.
            VStack(alignment: .leading, spacing: 8) {
                if let countdown {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Clap now — a few times, the way you normally would. \(countdown)s")
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                    }
                } else {
                    Button {
                        start()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "hands.clap.fill").font(.system(size: 11))
                            Text("Teach it my clap").font(.system(size: 12.5, weight: .medium))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Theme.accent))
                        .foregroundStyle(Theme.onAccent)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!state.settings.wakeWord)
                }

                if let result {
                    Text(result)
                        .font(.system(size: 11.5)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !state.settings.wakeWord {
                    Text("Switch the wake phrase on first — the microphone has to be open "
                       + "for it to hear anything.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider().overlay(Theme.hairline)

            HStack {
                Text("Room level")
                    .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                Spacer()
                Text("\(db(state.wake.roomLevel)) · a clap needs \(db(state.wake.clapThreshold))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textDim)
            }
            // Two bars: the room, and what the microphone is hearing right now. The live
            // one is the answer to "it is not detecting much" — a meter that visibly moves
            // when you speak proves the audio is reaching this code, and one that does not
            // move says the problem is upstream of every threshold in this panel.
            meter(state.wake.roomLevel)
            HStack {
                Text("Hearing now")
                    .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                Spacer()
                Text(db(state.wake.inputPeak))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textDim)
            }
            meter(state.wake.inputPeak)

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

    /// Records for a few seconds, then sets the dial from what it heard.
    private func start() {
        result = nil
        state.startClapCalibration()
        countdown = listenFor
        Task { @MainActor in
            for remaining in stride(from: listenFor - 1, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                countdown = remaining
            }
            countdown = nil
            guard let r = state.finishClapCalibration() else {
                result = "I heard nothing at all — is the microphone working?"
                return
            }
            result = r.advice
            guard r.isUsable else { return }
            state.settings.clapSensitivity = Double(r.sensitivity)
            state.wake.clapSensitivity = r.sensitivity
            state.wake.clearTrace()
        }
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
