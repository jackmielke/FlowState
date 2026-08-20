import SwiftUI
import VibeVoiceCore

/// Live view of the Claude Code jobs in flight.
///
/// A task runs for minutes with the voice loop idle, so without this the only evidence
/// anything is happening is a badge and a scrolling transcript shared with the
/// conversation. One card per job keeps them separable when several run at once.
struct TaskPanel: View {
    @ObservedObject var state: AppState
    /// Ticks so elapsed times count up without every card owning a timer.
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var tasks: [DevTask] {
        let r = state.devTasks
        return r.running.sorted { $0.startedAt < $1.startedAt }
             + r.finished.sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text("TASKS")
                    .font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.4)
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                Text("\(state.devTasks.running.count)/\(state.devTasks.maxConcurrent)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider().overlay(Theme.hairline)

            if tasks.isEmpty {
                VStack(spacing: 5) {
                    Text("No tasks yet")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                    Text("Ask for a code change and it runs here.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 22)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(tasks) { card($0) }
                    }
                    .padding(10)
                }
            }
        }
        .onReceive(clock) { now = $0 }
    }

    private func card(_ t: DevTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(tint(t.status)).frame(width: 6, height: 6)
                Text(t.id)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                Text(t.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(elapsed(t))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)

                if t.status == .running {
                    Button { Task { await state.cancelTask(t.id) } } label: {
                        Image(systemName: "stop.fill").font(.system(size: 8.5))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.badInk)
                    .help("Stop this task")
                } else {
                    Button { _ = state.undoTask(t.id) } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 8.5))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.textFaint)
                    .help("Roll this repo back to before \(t.id) started")
                }
            }

            Text((t.repo as NSString).lastPathComponent)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textFaint)

            // The newest steps only. The full log lives in the transcript; this is a
            // glanceable "what is it doing right now".
            if t.status == .running, !t.steps.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(t.steps.suffix(3).enumerated()), id: \.offset) { _, s in
                        Text("· " + s)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.textDim)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }

            if !t.deniedTools.isEmpty {
                Text("blocked: " + t.deniedTools.joined(separator: ", "))
                    .font(.system(size: 10)).foregroundStyle(Theme.badInk)
                    .lineLimit(2)
            } else if t.status.isTerminal, let r = t.result, !r.isEmpty {
                Text(r)
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textDim)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.fill))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(t.status == .running ? tint(t.status).opacity(0.45) : Theme.hairline, lineWidth: 1))
    }

    private func elapsed(_ t: DevTask) -> String {
        let s = Int(t.elapsed(now: now))
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func tint(_ s: DevTask.Status) -> Color {
        switch s {
        case .running:   return Theme.accent
        case .finished:  return Theme.good
        case .failed:    return Theme.bad
        case .blocked:   return Theme.voice
        case .cancelled: return Theme.textFaint
        }
    }
}
