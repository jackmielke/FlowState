import Foundation

/// What to do when a native tool is not going to answer in time to be spoken.
///
/// The realtime model is mute between calling a tool and being handed its output. For a
/// clipboard read that is invisible. For `web_search` (a model call plus a search),
/// `notion_read` (two HTTP round trips) or a Shortcut that opens an app, it is a hole in
/// the conversation where the assistant appears to have hung up — and the app's own
/// answer to that problem already exists in Dev Mode: reply *now*, report back *later*.
///
/// So a native tool gets a deadline. If it beats the deadline nothing changes — the
/// result goes back in the same turn, which is the whole reason native tools exist. If it
/// misses, the call is answered with a holding note, the model says four words, and the
/// real result is filed as a new turn when it lands.
///
/// `ToolLatencyBook` closes the loop: a tool that was slow the last few times is
/// announced *before* it is waited on, so the second slow Notion read costs no dead air
/// at all.
public enum SlowToolPolicy {

    /// How long a tool may take before the turn is handed back with a holding line.
    ///
    /// Two bands, and the split is not about how slow the tool is — it is about whether
    /// the tool touches the network. A local tool that overruns is broken, not slow, and
    /// the generous budget means the holding turn is never spent on a hiccup. A network
    /// tool that overruns is having an ordinary bad day.
    ///
    /// 1.8s is chosen against what a conversation tolerates, not against what an API
    /// promises: under about two seconds a pause reads as thinking, over it reads as a
    /// dropped call. Anything lower starts spending a whole spoken turn to save a
    /// silence nobody would have noticed.
    public static func budget(for tool: String) -> TimeInterval {
        switch tool {
        case "web_search", "notion_search", "notion_read":  return 1.8
        case "run_shortcut":                                return 2.5
        case "get_calendar", "list_shortcuts":              return 2.0
        default:                                            return 3.0
        }
    }

    /// True for tools that can plausibly overrun. Everything else is answered from
    /// memory or a file read, and racing it against a clock is pure overhead.
    public static func canBeSlow(_ tool: String) -> Bool {
        switch tool {
        case "web_search", "notion_search", "notion_read",
             "run_shortcut", "get_calendar", "list_shortcuts":
            return true
        default:
            return false
        }
    }

    /// The output handed back when the deadline passes. The model is told to say almost
    /// nothing, because the real answer is seconds away and two sentences of throat
    /// clearing would arrive on top of it.
    public static func holdingNote(for tool: String) -> String {
        "\(tool) is taking a moment. Say you're checking — four words or fewer, no detail, "
        + "no apology, and do NOT guess the answer. The real result arrives in a moment as "
        + "a new message; say it then."
    }

    /// The late result, filed as context once the tool finally answers.
    public static func lateNote(tool: String, result: String) -> String {
        "[\(tool) came back: \(result)] Answer the question they asked, from this, in one "
        + "or two sentences. Do not mention the delay."
    }
}

/// What each tool has actually cost lately, so the app can stop being surprised.
///
/// A rolling average per tool, deliberately short-memoried: an exponential blend where
/// the newest call is weighted a third. Two slow Notion reads are enough to change the
/// app's behaviour, and one fast one is enough to start changing it back — which is the
/// right shape for a signal about somebody's network, not about their software.
///
/// Not persisted. A new session starts optimistic on purpose: yesterday's bad Wi-Fi is
/// not evidence about today's.
public final class ToolLatencyBook {

    /// Weight of the newest sample. 1/3 gives an effective memory of about five calls.
    private let alpha: Double
    private var mean: [String: TimeInterval] = [:]
    private var samples: [String: Int] = [:]

    public init(alpha: Double = 1.0 / 3.0) {
        self.alpha = alpha
    }

    public func record(_ tool: String, seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        samples[tool, default: 0] += 1
        if let m = mean[tool] {
            mean[tool] = m + alpha * (seconds - m)
        } else {
            mean[tool] = seconds
        }
    }

    /// The blended cost of this tool so far, or nil if it has never run.
    public func expected(_ tool: String) -> TimeInterval? { mean[tool] }

    public func callCount(_ tool: String) -> Int { samples[tool] ?? 0 }

    /// True when history says waiting for this tool will cost a silence, so the holding
    /// line should go out immediately rather than after the deadline.
    ///
    /// Requires two calls before it will say yes. One slow call is an anecdote — and the
    /// first call of a session is exactly when a cold TLS handshake makes every tool look
    /// slow, which would otherwise make the app permanently pessimistic about the tool it
    /// happened to run first.
    public func expectsSlow(_ tool: String, budget: TimeInterval) -> Bool {
        guard SlowToolPolicy.canBeSlow(tool),
              let m = mean[tool], (samples[tool] ?? 0) >= 2 else { return false }
        return m > budget
    }

    /// One line per tool, slowest first — for the log, and for anyone wondering which
    /// tool is making the app feel sluggish.
    public var report: [String] {
        mean.sorted { $0.value > $1.value }
            .map { String(format: "%@ %.2fs (n=%d)", $0.key, $0.value, samples[$0.key] ?? 0) }
    }
}
