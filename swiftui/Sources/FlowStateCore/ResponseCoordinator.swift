import Foundation

/// One-response-at-a-time bookkeeping for the OpenAI realtime API.
///
/// The API rejects a `response.create` that arrives while a response is already
/// running, with:
///
///     Conversation already has an active response in progress
///
/// That is easy to hit, because a turn can be started from four independent places:
/// server VAD (`turn_detection.create_response: true`), a screenshot the user sends,
/// a `function_call_output` answering a tool call, and the system note filed when a
/// long Claude Code task finishes. Worse, the window that matters opens the moment we
/// *send* `response.create` — not when the server answers `response.created`. Tracking
/// only the server's view (the old `responseActive` flag) therefore left a full round
/// trip in which a second create looked perfectly legal, which is exactly how two
/// creates end up on the wire back to back.
///
/// So: everything that wants a spoken turn goes through `request(reason:)`, and only
/// this type is allowed to put `response.create` / `response.cancel` on the socket. At
/// most one create is ever in flight. Anything asked for while busy is coalesced into a
/// single follow-up turn, sent when the current response finishes — deferred, not
/// dropped, and never sent twice.
///
/// It is also defensive about getting stuck. Every phase carries a deadline; if the
/// server never confirms a create, never finishes a response, or never acknowledges a
/// cancel, `tick()` unwinds the state instead of leaving the app mute forever, and
/// `cancel(reason:)` / `reset(reason:)` give the UI an explicit way out.
///
/// Main-actor isolated: it is only ever touched from event handling on the main queue,
/// and saying so lets the app wire main-actor closures into it without ceremony.
@MainActor
public final class ResponseCoordinator {

    // MARK: - Types

    public enum Phase: String, Sendable, Equatable {
        /// No response running and none requested.
        case idle
        /// `response.create` is on the wire; the server has not said `response.created` yet.
        case requested
        /// The server confirmed a response is running.
        case active
        /// `response.cancel` is on the wire; waiting for `response.done`.
        case cancelling

        /// True whenever a new `response.create` would be rejected by the API.
        public var isBusy: Bool { self != .idle }
    }

    /// The only two messages this type is allowed to send.
    public enum Outbound: String, Sendable, Equatable {
        case create
        case cancel
    }

    /// A lifecycle log line. Structured rather than a bare string so tests can assert
    /// on what happened, and so the app can decide which kinds reach the transcript.
    public struct Event: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            /// `response.create` was put on the wire.
            case sent
            /// A request arrived while busy and was deferred.
            case queued
            /// A deferred request is being held back (user is speaking / VAD grace).
            case held
            /// The server confirmed a response is running.
            case started
            /// `response.done` arrived.
            case finished
            /// `response.cancel` was put on the wire.
            case cancelRequested
            /// A lifecycle error was understood and the state repaired.
            case recovered
            /// A phase overran its deadline and was unwound.
            case timedOut
            /// Queued requests were thrown away.
            case dropped
            /// State was cleared without talking to the server.
            case reset
            /// Nothing to do.
            case ignored
        }

        public let kind: Kind
        public let phase: Phase
        public let detail: String

        public init(kind: Kind, phase: Phase, detail: String) {
            self.kind = kind
            self.phase = phase
            self.detail = detail
        }

        /// A single line suitable for stderr.
        public var line: String { "\(kind.rawValue) [\(phase.rawValue)] \(detail)" }
    }

    /// Deadlines, all generous — they exist to unstick a broken session, not to police
    /// a slow one. A spoken answer can legitimately run for a minute or more.
    public struct Timeouts: Sendable, Equatable {
        /// `.requested` → `.active`: how long the server may take to confirm a create.
        public var confirm: TimeInterval
        /// `.active` → `.idle`: how long one response may run before we assume it is wedged.
        public var response: TimeInterval
        /// `.cancelling` → `.idle`: how long a cancel may take before we force the issue.
        public var cancel: TimeInterval
        /// How long to hold a queued create after the user stops speaking, so it does not
        /// race the response server VAD is about to create for that utterance.
        public var speechGrace: TimeInterval

        public init(confirm: TimeInterval = 10,
                    response: TimeInterval = 180,
                    cancel: TimeInterval = 5,
                    speechGrace: TimeInterval = 1.5) {
            self.confirm = confirm
            self.response = response
            self.cancel = cancel
            self.speechGrace = speechGrace
        }
    }

    // MARK: - Wiring

    // These are `@MainActor` in their TYPE, not just by where they are called from:
    // the bodies the app installs touch main-actor state (the socket, the transcript,
    // `@Published` mirrors), and a bare `(Outbound) -> Void` would strip that isolation
    // back off at the assignment.

    /// Puts a message on the socket. Set by the owner; no-op by default.
    public var send: @MainActor (Outbound) -> Void = { _ in }

    /// Receives every lifecycle event.
    public var log: @MainActor (Event) -> Void = { _ in }

    /// Called after any change the UI should see.
    public var onChange: @MainActor () -> Void = { }

    /// Injectable clock, so the watchdog can be tested without sleeping. Deliberately
    /// NOT actor-isolated — `Date.init` has to remain a valid value for it.
    public var now: () -> Date

    public var timeouts: Timeouts

    /// How many failed create attempts in a row before queued work is abandoned.
    /// Without this, a server that rejects every create would be retried forever.
    public var maxStrikes: Int = 3

    // MARK: - State

    public private(set) var phase: Phase = .idle
    /// Reasons waiting for a turn. Always collapsed into ONE `response.create`.
    public private(set) var queued: [String] = []
    public private(set) var userSpeaking = false

    /// Deadline for the current phase, if that phase has one.
    private var deadline: Date?
    /// Reason the in-flight create was sent for, so it can be re-queued if rejected.
    private var inFlight: String?
    /// Do not send before this instant (set when the user stops speaking).
    private var hold: Date?
    /// When `speech_started` arrived, so a `speech_stopped` that never comes cannot
    /// hold the queue shut forever.
    private var speakingSince: Date?
    /// Consecutive create attempts that produced no response.
    private var strikes = 0

    public init(timeouts: Timeouts = Timeouts(), now: @escaping () -> Date = Date.init) {
        self.timeouts = timeouts
        self.now = now
    }

    /// True when the API would reject a new create right now.
    public var isBusy: Bool { phase.isBusy }

    /// True when a turn has been asked for but not yet sent.
    public var hasQueuedRequest: Bool { !queued.isEmpty }

    public var queuedCount: Int { queued.count }

    // MARK: - Requesting a turn

    /// Asks for a spoken turn. Sends `response.create` if that is legal right now,
    /// otherwise defers it until the current response finishes.
    ///
    /// - Parameter reason: short label for the logs ("screenshot", "tool-output", …).
    public func request(reason: String) {
        queued.append(reason)
        if !pump() {
            emit(.queued, "\(reason) — \(queuedWaitExplanation())")
        }
        onChange()
    }

    // MARK: - Inbound events

    /// `response.created` — the server has a response running, whether we asked for it
    /// or server VAD started it on its own.
    public func responseCreated(id: String? = nil) {
        strikes = 0
        hold = nil
        let who: String
        switch phase {
        case .requested:  who = "ours (\(inFlight ?? "?"))"
        case .idle:       who = "server turn"
        case .active:     who = "UNEXPECTED — one was already active"
        case .cancelling: who = "arrived while cancelling"
        }
        phase = .active
        deadline = now() + timeouts.response
        inFlight = nil
        emit(.started, "id=\(id ?? "?") · \(who)")
        onChange()
    }

    /// `response.done` — whatever was running has ended (completed, cancelled, failed).
    /// Releases the lock and flushes at most one deferred request.
    public func responseFinished(status: String = "completed") {
        let waiting = queued.count
        phase = .idle
        deadline = nil
        inFlight = nil
        strikes = 0
        emit(.finished, waiting > 0 ? "status=\(status) · \(waiting) queued request(s) to flush"
                                    : "status=\(status)")
        pump()
        onChange()
    }

    /// The user started talking. Server VAD will truncate the current response and open
    /// a turn of its own, so nothing queued may go out until that has played through.
    public func userSpeechStarted() {
        userSpeaking = true
        speakingSince = now()
        hold = nil
        if !queued.isEmpty {
            emit(.held, "user is speaking — \(queued.count) queued request(s) wait")
        }
        onChange()
    }

    /// The user stopped talking. The server is about to create a response for that
    /// utterance (`turn_detection.create_response`), and sending our own create into
    /// that window is a guaranteed collision — so hold briefly and let the server go
    /// first. If no server turn materialises, `tick()` releases the queue.
    public func userSpeechStopped() {
        userSpeaking = false
        speakingSince = nil
        if !queued.isEmpty {
            hold = now() + timeouts.speechGrace
            emit(.held, "waiting \(fmt(timeouts.speechGrace))s for the server's own turn")
        } else {
            hold = nil
        }
        onChange()
    }

    /// Feeds an API `error` message through the lifecycle.
    ///
    /// - Returns: true if this was a response-lifecycle error that has now been repaired,
    ///   meaning the caller should NOT show it to the user as a failure.
    @discardableResult
    public func apiError(_ message: String) -> Bool {
        let m = message.lowercased()

        // The error this whole type exists to prevent. If it still happens — a race we
        // did not model, or a response created by a client we do not control — believe
        // the server: a response IS running, so take the lock and re-queue what we tried
        // to send so the user's intent is not silently lost.
        if m.contains("already has an active response") {
            strikes += 1
            let rejected = inFlight
            inFlight = nil
            if phase == .requested || phase == .idle {
                phase = .active
                deadline = now() + timeouts.response
            }
            var detail = "create rejected as duplicate — the server has an active response"
            if let rejected {
                queued.append(rejected)
                detail += "; re-queued \(rejected)"
            }
            detail += " (strike \(strikes)/\(maxStrikes))"
            emit(.recovered, detail)
            onChange()
            return true
        }

        // The mirror image: we cancelled something that had already ended.
        if m.contains("no active response") || m.contains("cancellation failed") {
            if phase == .cancelling {
                phase = .idle
                deadline = nil
                inFlight = nil
                emit(.recovered, "nothing was running to cancel — back to idle")
                pump()
            } else {
                emit(.ignored, "cancel error while \(phase.rawValue): \(message)")
            }
            onChange()
            return true
        }

        // Anything else is not ours to interpret. Deliberately does NOT touch the phase:
        // an unrelated error (a bad item id, say) must not free the lock while a response
        // is genuinely running. If a create really was lost, `tick()` picks it up.
        return false
    }

    // MARK: - Cancel / reset

    /// Stops the current response and abandons anything queued behind it.
    ///
    /// This is the user-facing "Stop": it means silence, so queued turns are dropped
    /// too rather than starting up the moment the current one dies. Pressing it a
    /// second time while a cancel is already in flight forces the state back to idle —
    /// the escape hatch for a server that never acknowledges the cancel.
    public func cancel(reason: String) {
        switch phase {
        case .requested, .active:
            dropQueued(because: reason)
            phase = .cancelling
            deadline = now() + timeouts.cancel
            inFlight = nil
            emit(.cancelRequested, reason)
            send(.cancel)
        case .cancelling:
            emit(.timedOut, "cancel asked for twice — forcing idle")
            reset(reason: "forced by \(reason)")
            return
        case .idle:
            if queued.isEmpty {
                emit(.ignored, "nothing to cancel (\(reason))")
            } else {
                dropQueued(because: reason)
            }
        }
        onChange()
    }

    /// Clears all local state without sending anything. For disconnects, new sessions
    /// and the UI's hard reset — a queued create left over from a dead socket must never
    /// fire into the next session.
    public func reset(reason: String) {
        let hadWork = phase != .idle || !queued.isEmpty
        phase = .idle
        queued.removeAll()
        deadline = nil
        inFlight = nil
        hold = nil
        strikes = 0
        userSpeaking = false
        speakingSince = nil
        if hadWork { emit(.reset, reason) } else { emit(.reset, "\(reason) (nothing in flight)") }
        onChange()
    }

    // MARK: - Watchdog

    /// Drives the deadlines and releases held work. Safe to call as often as you like;
    /// the app runs it once a second while the session is live.
    public func tick() {
        let t = now()

        // `speech_started` with no `speech_stopped` behind it — a dropped event, or VAD
        // that never closed the turn. Releasing is the lesser evil: at worst the create
        // collides and self-heals, whereas holding means the app never speaks again.
        if userSpeaking, let since = speakingSince, t.timeIntervalSince(since) >= timeouts.response {
            userSpeaking = false
            speakingSince = nil
            hold = nil
            emit(.timedOut, "no speech_stopped within \(fmt(timeouts.response))s — releasing the hold")
            onChange()
        }

        if let d = deadline, t >= d {
            switch phase {
            case .requested:
                // The create never came back. Free the lock so the app is not mute
                // forever, and put the request back on the queue — the turn it was
                // asking for still has not happened. `strikes` is what stops that
                // becoming an infinite retry against a server that keeps refusing.
                strikes += 1
                phase = .idle
                deadline = nil
                if let lost = inFlight { queued.insert(lost, at: 0) }
                inFlight = nil
                emit(.timedOut, "no response.created within \(fmt(timeouts.confirm))s (strike \(strikes)/\(maxStrikes))")
            case .active:
                phase = .cancelling
                deadline = t + timeouts.cancel
                emit(.timedOut, "no response.done within \(fmt(timeouts.response))s — cancelling")
                send(.cancel)
            case .cancelling:
                phase = .idle
                deadline = nil
                inFlight = nil
                emit(.timedOut, "cancel not acknowledged within \(fmt(timeouts.cancel))s — forcing idle")
            case .idle:
                deadline = nil
            }
            onChange()
        }
        // pump() can also abandon queued work, which the UI needs to see, so compare
        // rather than trusting "did it send".
        let phaseBefore = phase
        let queuedBefore = queued.count
        pump()
        if phase != phaseBefore || queued.count != queuedBefore { onChange() }
    }

    // MARK: - Internals

    /// Sends the queued request if — and only if — doing so is legal right now.
    /// The single choke point: no other path may call `send(.create)`.
    @discardableResult
    private func pump() -> Bool {
        guard phase == .idle, !queued.isEmpty else { return false }

        if strikes >= maxStrikes {
            let lost = queued.joined(separator: ", ")
            queued.removeAll()
            emit(.dropped, "\(strikes) failed attempts in a row — abandoning: \(lost)")
            strikes = 0
            return false
        }
        guard !userSpeaking else { return false }
        if let h = hold {
            guard now() >= h else { return false }
            hold = nil
        }

        let reason = queued.joined(separator: " + ")
        queued.removeAll()
        inFlight = reason
        phase = .requested
        deadline = now() + timeouts.confirm
        emit(.sent, reason)
        send(.create)
        return true
    }

    private func dropQueued(because reason: String) {
        guard !queued.isEmpty else { return }
        let lost = queued.joined(separator: ", ")
        queued.removeAll()
        emit(.dropped, "\(reason) — dropped: \(lost)")
    }

    private func queuedWaitExplanation() -> String {
        if userSpeaking { return "user is speaking" }
        if let h = hold, now() < h { return "waiting for the server's own turn" }
        switch phase {
        case .requested:  return "a response.create is already in flight"
        case .active:     return "a response is already running"
        case .cancelling: return "a cancel is in flight"
        case .idle:       return "strike limit reached"
        }
    }

    private func emit(_ kind: Event.Kind, _ detail: String) {
        log(Event(kind: kind, phase: phase, detail: detail))
    }

    private func fmt(_ t: TimeInterval) -> String {
        t == t.rounded() ? String(Int(t)) : String(format: "%.1f", t)
    }
}
