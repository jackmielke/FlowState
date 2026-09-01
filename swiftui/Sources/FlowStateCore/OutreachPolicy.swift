import Foundation

/// Everything the decision to speak first depends on.
///
/// Gathered by the app and passed in whole, rather than read here, so the rule can be
/// tested against situations that are a nuisance to arrange for real — three in the
/// morning, a meeting running long, a laptop that has been shut since lunch.
public struct OutreachContext: Equatable, Sendable {
    public var now: Date
    /// Since the last keyboard or mouse event. The cheapest evidence that somebody is
    /// actually at the machine.
    public var idleSeconds: Double
    public var screenLocked: Bool
    /// A calendar event is happening right now.
    public var inMeeting: Bool
    /// A conferencing app is running — Zoom, Teams, FaceTime, a Meet tab.
    public var conferencingApp: Bool
    /// A conversation is already open, so there is nothing to interrupt.
    public var inSession: Bool
    public var lastSpokeAt: Date?
    public var snoozedUntil: Date?
    /// Inside the hours the user said they are available.
    public var withinHours: Bool

    public init(now: Date,
                idleSeconds: Double = 0,
                screenLocked: Bool = false,
                inMeeting: Bool = false,
                conferencingApp: Bool = false,
                inSession: Bool = false,
                lastSpokeAt: Date? = nil,
                snoozedUntil: Date? = nil,
                withinHours: Bool = true) {
        self.now = now
        self.idleSeconds = idleSeconds
        self.screenLocked = screenLocked
        self.inMeeting = inMeeting
        self.conferencingApp = conferencingApp
        self.inSession = inSession
        self.lastSpokeAt = lastSpokeAt
        self.snoozedUntil = snoozedUntil
        self.withinHours = withinHours
    }
}

public enum OutreachDecision: Equatable, Sendable {
    /// Open a session and say it.
    case speak
    /// A conversation is already running — put it in that, without opening anything.
    case inline
    /// Not now. The reason is spoken later ("I sat on this while you were in a call"),
    /// so it is written as something a person would say.
    case hold(String)
    /// Never mind. Too old to be worth hearing.
    case drop(String)
}

/// Whether an assistant that can talk whenever it likes should talk *now*.
///
/// This is the whole feature. Something that speaks up unprompted is either the most
/// useful thing on the machine or the first thing uninstalled, and which one it is comes
/// down to a handful of judgements about when to keep quiet. So they are here, in one
/// place, with tests — rather than spread across the code that happens to notice things.
///
/// The bias throughout is toward silence. A missed update costs a few minutes; one
/// spoken over a sentence in somebody else's meeting costs the whole feature.
public struct OutreachPolicy: Equatable, Sendable {

    /// Away from the keyboard for this long and nobody is listening. Held, not dropped —
    /// they will come back.
    public var awayAfter: TimeInterval = 180

    /// The shortest gap between two unprompted interruptions.
    public var minimumGap: TimeInterval = 600

    /// After this long unsaid, an update is history rather than news. "That task you
    /// started finished — two hours ago" is worse than nothing, because it teaches the
    /// user that what it says is not current.
    public var expiresAfter: TimeInterval = 2 * 3_600

    public init() {}

    /// The signals this machine can and cannot supply, written down because the gap is
    /// the interesting part.
    ///
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input looks like the
    /// perfect "is he on a call" test and is useless here: measured on this Mac it reads
    /// true continuously, with FlowState quit, because a dictation tool holds the
    /// microphone open all day. An always-on microphone is exactly the kind of tool
    /// somebody with a wrist injury runs, so this is not an unlucky machine — it is the
    /// target machine.
    ///
    /// Hence `inMeeting` from the calendar and `conferencingApp` from the process list
    /// instead: both coarser, neither fooled by a dictation tool. Idle time and the lock
    /// screen are exact and cost no permission, which is why they are checked first.

    public func decide(_ c: OutreachContext, raisedAt: Date) -> OutreachDecision {
        // Old news first, so nothing else can resurrect it. Checked before `inSession`
        // too: being mid-conversation is not a reason to hear something stale.
        if c.now.timeIntervalSince(raisedAt) > expiresAfter {
            return .drop("it stopped being news")
        }

        // Already talking. Nothing is being interrupted, so none of the quiet rules
        // apply — they are all about the cost of *starting* a conversation.
        if c.inSession { return .inline }

        if c.screenLocked { return .hold("your screen was locked") }

        // Deliberately before the meeting checks: away is the more certain signal, and
        // "you were away" is a truer thing to say than guessing about a call.
        if c.idleSeconds >= awayAfter { return .hold("you were away from your desk") }

        if c.inMeeting { return .hold("your calendar said you were in something") }
        if c.conferencingApp { return .hold("you looked like you were on a call") }

        if let until = c.snoozedUntil, c.now < until { return .hold("you asked me to hold off") }
        if !c.withinHours { return .hold("it was outside the hours you set") }

        if let last = c.lastSpokeAt, c.now.timeIntervalSince(last) < minimumGap {
            return .hold("I had only just interrupted you")
        }

        return .speak
    }
}
