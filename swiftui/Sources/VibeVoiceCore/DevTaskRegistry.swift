import Foundation

/// One dispatched Claude Code job.
public struct DevTask: Identifiable, Equatable {

    public enum Status: String, Equatable {
        case running, finished, failed, blocked, cancelled

        public var isTerminal: Bool { self != .running }
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
    }

    public internal(set) var tasks: [DevTask] = []
    public let maxConcurrent: Int
    private var counter = 0

    public init(maxConcurrent: Int = 3) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    public var running: [DevTask] { tasks.filter { $0.status == .running } }
    public var finished: [DevTask] { tasks.filter { $0.status.isTerminal } }

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

    public func cancel(_ id: String, now: Date = Date()) {
        guard let i = index(id), tasks[i].status == .running else { return }
        tasks[i].status = .cancelled
        tasks[i].finishedAt = now
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
