import Foundation

/// Everything needed to actually start a job, kept so a task can wait its turn.
///
/// A queued task is a promise to run something later, and a promise that has forgotten
/// what it promised is worthless — so the instruction travels with the task rather than
/// staying in the call that enqueued it.
public struct DevTaskRequest: Equatable, Sendable {
    public var instruction: String
    public var permissionMode: String
    /// The task whose Claude Code session this one continues, if any. Stored as a task
    /// id rather than a session id because a task that has not finished yet does not
    /// have a session id to store.
    public var resumeTaskID: String?

    public init(instruction: String, permissionMode: String, resumeTaskID: String? = nil) {
        self.instruction = instruction
        self.permissionMode = permissionMode
        self.resumeTaskID = resumeTaskID
    }
}

/// One dispatched Claude Code job.
public struct DevTask: Identifiable, Equatable {

    public enum Status: String, Equatable {
        case queued, running, finished, failed, blocked, cancelled

        /// Finished, one way or another. A queued task has not started, so it is no more
        /// terminal than a running one.
        public var isTerminal: Bool { self != .running && self != .queued }
    }

    /// Short and speakable — "task one", not a UUID. The model refers to these out loud,
    /// so they have to survive being said and heard.
    public let id: String
    public var label: String
    public var repo: String
    public var status: Status = .running
    public var steps: [String] = []
    public var startedAt: Date
    public var finishedAt: Date?
    public var result: String?
    public var deniedTools: [String] = []
    /// Claude Code's own session id, so a follow-up resumes THIS task's context.
    public var claudeSessionID: String?
    /// What to run, kept only while the task is waiting for its turn.
    public var request: DevTaskRequest?
    /// When it joined the queue. `startedAt` is reset the moment it actually starts, so
    /// "ran for 40s" never silently includes an hour spent waiting.
    public var queuedAt: Date?

    public init(id: String, label: String, repo: String, startedAt: Date) {
        self.id = id
        self.label = label
        self.repo = repo
        self.startedAt = startedAt
    }

    public func elapsed(now: Date) -> TimeInterval {
        (finishedAt ?? now).timeIntervalSince(startedAt)
    }
}

/// Bookkeeping for several Claude Code jobs at once.
///
/// Pure logic on purpose: the rules worth getting right (how many may run, what may run
/// beside what, which task a follow-up resumes) are all decidable without spawning a
/// process, so they are all testable.
public final class DevTaskRegistry {

    public enum RejectionReason: Equatable {
        case atCapacity(limit: Int)
        case repoBusy(taskID: String, repo: String)

        public var spokenExplanation: String {
            switch self {
            case .atCapacity(let n):
                return "Already running \(n) tasks, which is the limit. Wait for one to finish."
            case .repoBusy(let id, let repo):
                return "Task \(id) is already working in \(repo). Two jobs editing the same "
                     + "repo at once corrupt each other's builds — wait for it, or point "
                     + "this one at a different repo."
            }
        }

        /// The same fact said as a wait rather than a refusal — which is what it now is:
        /// a task that cannot start is queued, not turned away.
        public var queuedExplanation: String {
            switch self {
            case .atCapacity(let n):
                return "\(n) tasks are already running, so this one is queued and starts as "
                     + "soon as one of them finishes."
            case .repoBusy(let id, let repo):
                return "Task \(id) is already working in \(repo), so this one is queued "
                     + "behind it and starts the moment it finishes."
            }
        }
    }

    public internal(set) var tasks: [DevTask] = []
    public let maxConcurrent: Int
    private var counter = 0

    public init(maxConcurrent: Int = 3) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    public var running: [DevTask] { tasks.filter { $0.status == .running } }
    public var finished: [DevTask] { tasks.filter { $0.status.isTerminal } }
    /// Waiting tasks, in the order they will run. Array order IS queue order — that is
    /// what makes reordering a swap rather than a re-sort.
    public var queued: [DevTask] { tasks.filter { $0.status == .queued } }

    /// While paused, nothing new starts.
    ///
    /// A running task is deliberately NOT interrupted: pausing a queue means "stop
    /// taking on more", not "abandon what is half-done". Stopping something already
    /// underway is what the stop button is for, and conflating the two would make pause
    /// a destructive action nobody would risk pressing.
    public private(set) var isPaused = false

    public func pause() { isPaused = true }
    public func resume() { isPaused = false }
    public func setPaused(_ p: Bool) { isPaused = p }

    /// What to say about the pause, given what is actually waiting.
    public var pauseExplanation: String {
        guard isPaused else { return "" }
        let n = queued.count
        let running = self.running.count
        if running > 0 && n > 0 {
            return "Queue paused. Finishing the \(running == 1 ? "current task" : "\(running) running tasks"), "
                 + "then stopping — \(n) waiting."
        }
        if running > 0 { return "Queue paused. Finishing the current task, then stopping." }
        if n > 0 { return "Queue paused. \(n) task\(n == 1 ? "" : "s") waiting." }
        return "Queue paused. Nothing waiting."
    }

    public func task(_ id: String) -> DevTask? { tasks.first { $0.id == id } }

    /// Why a new task in `repo` cannot start, or nil if it can.
    ///
    /// The repo rule is not caution for its own sake: two Claude Code runs editing one
    /// checkout genuinely break each other — a build started by one fails with "input
    /// file was modified during the build" when the other writes mid-compile.
    public func rejectionFor(repo: String) -> RejectionReason? {
        let normalised = Self.normalise(repo)
        if let clash = running.first(where: { Self.normalise($0.repo) == normalised }) {
            return .repoBusy(taskID: clash.id, repo: clash.repo)
        }
        if running.count >= maxConcurrent {
            return .atCapacity(limit: maxConcurrent)
        }
        return nil
    }

    public func canStart(repo: String) -> Bool { rejectionFor(repo: repo) == nil }

    @discardableResult
    public func start(label: String, repo: String, now: Date = Date()) -> DevTask {
        counter += 1
        let t = DevTask(id: "T\(counter)", label: label, repo: repo, startedAt: now)
        tasks.append(t)
        return t
    }

    /// Adds a task that is not allowed to start yet.
    ///
    /// Never refused. Refusing was the old behaviour and it put the user in charge of
    /// scheduling — "wait for it, or point this one at a different repo" is a chore
    /// handed back to somebody who is talking, not typing. The repo rule is unchanged;
    /// what changed is that breaking it means *later*, not *no*.
    @discardableResult
    public func enqueue(label: String, repo: String, request: DevTaskRequest,
                        now: Date = Date()) -> DevTask {
        counter += 1
        var t = DevTask(id: "T\(counter)", label: label, repo: repo, startedAt: now)
        t.status = .queued
        t.queuedAt = now
        t.request = request
        tasks.append(t)
        return t
    }

    /// Where a queued task sits, 1-based. Nil once it is no longer waiting.
    public func queuePosition(_ id: String) -> Int? {
        queued.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// The next queued task that may start right now, marked running — or nil.
    ///
    /// "May start" is the same question `rejectionFor` already answers, so the queue
    /// cannot leak past the one-job-per-repo rule: a task whose repo is busy is skipped
    /// and one further down the queue for a free repo goes first. Call it in a loop
    /// after every completion; it returns nil as soon as nothing else may start.
    public func startNextQueued(now: Date = Date()) -> DevTask? {
        // Checked HERE rather than at the call site so a pause cannot be routed around:
        // every path to starting queued work goes through this one function.
        guard !isPaused else { return nil }
        for waiting in queued where canStart(repo: waiting.repo) {
            guard let i = index(waiting.id) else { continue }
            tasks[i].status = .running
            tasks[i].startedAt = now
            return tasks[i]
        }
        return nil
    }

    /// Moves a queued task one place earlier (-1) or later (+1). Returns false when it
    /// is already at the end it is being moved towards.
    @discardableResult
    public func moveQueued(_ id: String, by delta: Int) -> Bool {
        guard delta != 0, let from = queued.firstIndex(where: { $0.id == id }) else { return false }
        let to = from + delta
        guard queued.indices.contains(to) else { return false }
        // `move(from:to:)` takes SwiftUI's insertion-index convention, where moving
        // later means naming the slot *after* the target.
        moveQueued(from: from, to: delta > 0 ? to + 1 : to)
        return true
    }

    /// Reorders the queue, in `List`/`onMove` terms: `to` is an insertion point, so
    /// moving item 0 down one place is `from: 0, to: 2`.
    public func moveQueued(from source: Int, to destination: Int) {
        var order = queued
        guard order.indices.contains(source) else { return }
        let clamped = min(max(destination, 0), order.count)
        let moved = order.remove(at: source)
        order.insert(moved, at: clamped > source ? clamped - 1 : clamped)
        // Written back into the slots the queued tasks already occupied, so running and
        // finished tasks keep their places and their history.
        let slots = tasks.indices.filter { tasks[$0].status == .queued }
        for (slot, task) in zip(slots, order) { tasks[slot] = task }
    }

    public func addStep(_ step: String, to id: String) {
        guard let i = index(id) else { return }
        // Collapse a repeated step rather than filling the panel with the same line.
        if tasks[i].steps.last == step { return }
        tasks[i].steps.append(step)
        if tasks[i].steps.count > 40 { tasks[i].steps.removeFirst() }
    }

    public func setSessionID(_ sid: String?, for id: String) {
        guard let i = index(id), let sid else { return }
        tasks[i].claudeSessionID = sid
    }

    public func finish(_ id: String,
                       ok: Bool,
                       result: String,
                       deniedTools: [String] = [],
                       now: Date = Date()) {
        guard let i = index(id) else { return }
        // A blocked tool is its own outcome: the job neither succeeded nor crashed, it
        // was refused permission, and the fix is a setting rather than a retry.
        tasks[i].status = !deniedTools.isEmpty ? .blocked : (ok ? .finished : .failed)
        tasks[i].result = result
        tasks[i].deniedTools = deniedTools
        tasks[i].finishedAt = now
    }

    /// Stops a running task, or drops a queued one. Both are "I have changed my mind",
    /// and a queue you cannot take something out of is a trap.
    /// - Returns: true if the task was removed outright rather than marked cancelled.
    @discardableResult
    public func cancel(_ id: String, now: Date = Date()) -> Bool {
        guard let i = index(id), !tasks[i].status.isTerminal else { return false }

        // A queued task that never started is DELETED, not filed as cancelled.
        //
        // Cancelling one used to leave a card behind in the finished list, which is the
        // opposite of what dismissing something means: it never ran, changed nothing, and
        // produced no result, so there is nothing to keep a record of. A running task is
        // different — it did work, possibly to the working tree, and that is worth a row
        // saying so.
        if tasks[i].status == .queued {
            tasks.remove(at: i)
            return true
        }

        tasks[i].status = .cancelled
        tasks[i].finishedAt = now
        tasks[i].request = nil
        return false
    }

    /// The task a bare follow-up ("make it faster") should resume: the most recent one,
    /// preferring something still running.
    public func mostRecentResumable() -> DevTask? {
        running.max(by: { $0.startedAt < $1.startedAt })
            ?? tasks.filter { $0.claudeSessionID != nil }.max(by: { $0.startedAt < $1.startedAt })
    }

    /// Drops old terminal tasks so a long session does not grow without bound.
    public func pruneFinished(keeping: Int = 8) {
        let done = finished
        guard done.count > keeping else { return }
        let drop = Set(done
            .sorted { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
            .prefix(done.count - keeping)
            .map(\.id))
        tasks.removeAll { drop.contains($0.id) }
    }

    private func index(_ id: String) -> Int? { tasks.firstIndex { $0.id == id } }

    /// `~/dev/x`, `~/dev/x/`, and the expanded path are all the same checkout.
    static func normalise(_ repo: String) -> String {
        var p = (repo as NSString).expandingTildeInPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

public extension DevTaskRegistry {
    /// Puts a finished task back into `running` so a follow-up continues it in place
    /// rather than appearing as a brand-new job.
    func reopen(_ id: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].status = .running
        tasks[i].finishedAt = nil
    }
}

public extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
