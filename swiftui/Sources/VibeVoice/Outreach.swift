import Foundation
import AppKit
import CoreGraphics
import AVFoundation
import VibeVoiceCore

/// The assistant speaking first.
///
/// Something worth saying happens — a coding task finishes — and this decides whether to
/// say it now, sit on it, or let it go. `OutreachPolicy` holds the judgement and the
/// tests; this gathers the evidence and does what it is told.
@MainActor
final class Outreach {

    struct Pending {
        let raisedAt: Date
        let text: String
    }

    var policy = OutreachPolicy()
    private(set) var queue: [Pending] = []
    private(set) var lastSpokeAt: Date?
    var snoozedUntil: Date?

    /// Asked for whatever the app knows that this cannot see for itself.
    var isInSession: (() -> Bool)?
    /// Opens a session and says it. The caller owns connecting.
    var speak: ((String) -> Void)?
    /// Says it into a conversation that is already running.
    var sayInline: ((String) -> Void)?

    /// Conferencing apps, by bundle id. A running Zoom is not proof of a call, but this
    /// errs toward silence on purpose — see `OutreachPolicy`.
    private static let conferencing: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2",
        "com.apple.FaceTime", "com.hnc.Discord", "com.webex.meetingmanager",
        "com.cisco.webexmeetingsapp", "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan",
    ]

    func raise(_ text: String, at when: Date = Date()) {
        queue.append(Pending(raisedAt: when, text: text))
        flush()
    }

    /// Called on a timer as well as on arrival, so something held while the user was in a
    /// meeting is delivered when they come out of it rather than never.
    func flush(now: Date = Date()) {
        guard !queue.isEmpty else { return }
        let context = snapshot(now: now)

        var carried: [Pending] = []
        var sayNow: [Pending] = []
        for item in queue {
            switch policy.decide(context, raisedAt: item.raisedAt) {
            case .speak, .inline: sayNow.append(item)
            case .hold:           carried.append(item)
            case .drop:           break
            }
        }
        queue = carried
        guard let first = sayNow.first else { return }

        // Everything waiting goes in one interruption. Three separate ones about three
        // finished tasks is three times the cost of the same information.
        let body = sayNow.map(\.text).joined(separator: " Also, ")
        let held = context.now.timeIntervalSince(first.raisedAt)
        let preface = held > policy.minimumGap
            ? "I held on to this — " : ""

        if case .inline = policy.decide(context, raisedAt: first.raisedAt) {
            sayInline?(preface + body)
        } else {
            lastSpokeAt = context.now
            speak?(preface + body)
        }
    }

    private func snapshot(now: Date) -> OutreachContext {
        OutreachContext(
            now: now,
            idleSeconds: Self.idleSeconds(),
            screenLocked: Self.screenLocked(),
            // Not wired yet: the calendar read is async and this is not. Conferencing
            // apps carry the meeting case on their own for now, and the policy already
            // treats either as a reason to keep quiet.
            inMeeting: false,
            conferencingApp: Self.conferencingAppRunning(),
            inSession: isInSession?() ?? false,
            lastSpokeAt: lastSpokeAt,
            snoozedUntil: snoozedUntil,
            withinHours: true)
    }

    /// Seconds since the last keyboard or mouse event, from any app. No permission.
    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState,
                                                eventType: .init(rawValue: ~0)!)
    }

    static func screenLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    /// A conferencing app that looks like it is actually in a call.
    ///
    /// "Is Zoom running" is not the question, and asking it was wrong in the first test:
    /// FaceTime sitting open in the dock held every update indefinitely. An app that has
    /// been left running is the normal state of a Mac, not evidence of anything.
    ///
    /// So it also has to be either frontmost, or holding the camera. The camera is the
    /// stronger signal — nothing has it open except a call or a recording — and it is
    /// checked against *another* application, so FlowState's own bubble does not count
    /// itself as a meeting.
    static func conferencingAppRunning() -> Bool {
        let running = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return conferencing.contains(id)
        }
        guard !running.isEmpty else { return false }
        if running.contains(where: { $0.isActive }) { return true }
        return AVCaptureDevice.default(for: .video)?.isInUseByAnotherApplication ?? false
    }
}
