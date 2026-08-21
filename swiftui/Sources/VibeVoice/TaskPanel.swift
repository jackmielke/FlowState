import SwiftUI
import VibeVoiceCore

/// Live view of the Claude Code jobs — running, waiting, and just finished.
///
/// A task runs for minutes with the voice loop idle, so without this the only evidence
/// anything is happening is a badge and a scrolling transcript shared with the
/// conversation. One card per job keeps them separable when several run at once.
///
/// The queue is here rather than only in the model's head because a task that will run
/// "later" is a promise, and a promise you cannot see, reorder or take back is worse
/// than a refusal.
struct TaskPanel: View {
    @ObservedObject var state: AppState
    /// Ticks so elapsed times count up without every card owning a timer.
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var running: [DevTask] {
        state.devTasks.running.sorted { $0.startedAt < $1.startedAt }
    }
    private var queued: [DevTask] { state.devTasks.queued }
    private var finished: [DevTask] {
        state.devTasks.finished.sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text("TASKS")
                    .font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.4)
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                if !queued.isEmpty {
                    Text("\(queued.count) queued")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.fill)
                            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1)))
                }
                Text("\(running.count)/\(state.devTasks.maxConcurrent)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider().overlay(Theme.hairline)

            if running.isEmpty && queued.isEmpty && finished.isEmpty {
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
                        ForEach(running) { card($0) }

                        if !queued.isEmpty {
                            sectionLabel("NEXT UP · runs automatically")
                            ForEach(Array(queued.enumerated()), id: \.element.id) { i, t in
                                queuedCard(t, position: i + 1, isFirst: i == 0,
                                           isLast: i == queued.count - 1)
                            }
                        }

                        ForEach(finished) { card($0) }
                    }
                    .padding(10)
                }
            }
        }
        .onReceive(clock) { now = $0 }
    }

    private func sectionLabel(_ s: String) -> some View {
        HStack(spacing: 6) {
            Text(s)
                .font(.system(size: 8.5, weight: .bold, design: .rounded)).tracking(1.1)
                .foregroundStyle(Theme.textFaint)
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .padding(.top, 2)
    }

    // MARK: - Running and finished

    private func card(_ t: DevTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(tint(t.status)).frame(width: 6, height: 6)
                Text(t.id)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                Text(Markdown.plain(t.label))
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
                // Claude Code answers in markdown by nature — bullets and bold in a
                // result are the norm, not the exception.
                MarkdownText(text: r, size: 10.5, color: Theme.textDim,
                             lineSpacing: 2, blockSpacing: 4, lineLimit: 3, maxBlocks: 4)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.fill))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(t.status == .running ? tint(t.status).opacity(0.45) : Theme.hairline, lineWidth: 1))
    }

    // MARK: - Queued

    private func queuedCard(_ t: DevTask, position: Int, isFirst: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(position)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.textFaint)
                .frame(width: 12, alignment: .trailing)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(t.id)
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.textFaint)
                    Text(Markdown.plain(t.label))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                HStack(spacing: 6) {
                    Text((t.repo as NSString).lastPathComponent)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textFaint)
                    Text(waitingOn(t))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textFaint.opacity(0.85))
                        .lineLimit(1)
                }
            }

            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    reorderButton("chevron.up", enabled: !isFirst, help: "Run \(t.id) sooner") {
                        state.moveQueuedTask(t.id, by: -1)
                    }
                    reorderButton("chevron.down", enabled: !isLast, help: "Run \(t.id) later") {
                        state.moveQueuedTask(t.id, by: 1)
                    }
                }
                Button { Task { await state.cancelTask(t.id) } } label: {
                    Image(systemName: "xmark").font(.system(size: 8))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textFaint)
                .help("Take \(t.id) out of the queue")
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Theme.fill.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(Theme.hairlineHi))
    }

    private func reorderButton(_ symbol: String, enabled: Bool, help: String,
                               _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
                .frame(width: 15, height: 13)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.fill))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.textDim : Theme.textFaint.opacity(0.35))
        .disabled(!enabled)
        .help(help)
    }

    /// Names what a queued task is actually waiting for, because "queued" alone invites
    /// the question and the answer is always knowable.
    private func waitingOn(_ t: DevTask) -> String {
        let sameRepo = running.first {
            (($0.repo as NSString).expandingTildeInPath) == ((t.repo as NSString).expandingTildeInPath)
        }
        if let sameRepo { return "waiting for \(sameRepo.id)" }
        if running.count >= state.devTasks.maxConcurrent { return "waiting for a free slot" }
        return "starting…"
    }

    private func elapsed(_ t: DevTask) -> String {
        let s = Int(t.elapsed(now: now))
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func tint(_ s: DevTask.Status) -> Color {
        switch s {
        case .queued:    return Theme.textFaint
        case .running:   return Theme.accent
        case .finished:  return Theme.good
        case .failed:    return Theme.bad
        case .blocked:   return Theme.voice
        case .cancelled: return Theme.textFaint
        }
    }
}
