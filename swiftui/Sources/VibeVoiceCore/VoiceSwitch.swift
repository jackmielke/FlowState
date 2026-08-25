import Foundation

/// Changing which voice the assistant speaks in.
///
/// The realtime API fixes the output voice when the session is created. A `session.update`
/// carrying a new voice is accepted while the session is silent and **rejected once the
/// model has produced any audio** — so for the whole of a real conversation, "apply it
/// live" is not a thing that exists. The old behaviour said "you'll hear it on the next
/// reply" and then kept the old voice for the rest of the session, which is the worst of
/// the options: a setting that reports success and does nothing.
///
/// So a voice change on a live session is a reconnect. That is a real cost — the socket
/// goes down, the model's own context of the conversation goes with it — and it is paid
/// deliberately here rather than pushed onto the user as "disconnect and reconnect for
/// this to take effect". The app's own transcript is not affected: it belongs to the
/// conversation, not to the socket, and survives the swap the same way it survives a
/// dropped connection.
///
/// The decision is here, in Core, because it has four outcomes and all four are about
/// state rather than about audio: nothing to do, nothing to reconnect, a name we do not
/// ship, and the reconnect itself.
public enum VoiceSwitch {

    /// What a requested voice change actually means.
    public enum Plan: Equatable, Sendable {
        /// Already speaking in it. Reconnecting would drop the conversation for nothing.
        case unchanged
        /// Not a voice this build knows. Nothing is stored — a settings file holding a
        /// name the API will reject is a session that fails to start later, somewhere
        /// that has nothing to do with the voice picker.
        case unknown(String)
        /// Stored; no session is up, so the next connect is the first time it matters.
        case stored
        /// Stored, and a session is up in the old voice: take it down and bring it back.
        case reconnect
    }

    /// - Parameters:
    ///   - live: a socket is open OR opening. Connecting counts — a session created a
    ///     moment from now would be created with the old voice.
    ///   - known: the voices this build offers. Matching is case- and space-insensitive
    ///     so a spoken "Marin " and a picked "marin" are the same request.
    public static func plan(from current: String,
                            to next: String,
                            live: Bool,
                            known: [String]) -> Plan {
        let wanted = normalize(next)
        guard !wanted.isEmpty else { return .unknown(next.trimmingCharacters(in: .whitespaces)) }
        guard let match = known.first(where: { normalize($0) == wanted }) else {
            return .unknown(next.trimmingCharacters(in: .whitespaces))
        }
        guard normalize(current) != normalize(match) else { return .unchanged }
        return live ? .reconnect : .stored
    }

    /// The canonical spelling to store, for a plan that stores anything.
    public static func resolve(_ next: String, known: [String]) -> String? {
        known.first { normalize($0) == normalize(next) }
    }

    /// The transcript line. `nil` when there is nothing worth saying — asking for the
    /// voice you are already using should not leave a mark on the conversation.
    ///
    /// The reconnect case says what is about to happen BEFORE it happens, because the
    /// user did not ask for a disconnect and is about to see one.
    public static func note(_ plan: Plan, voice: String, known: [String] = []) -> String? {
        switch plan {
        case .unchanged:
            return nil
        case .unknown(let asked):
            if asked.isEmpty { return "I didn't catch which voice you wanted." }
            return known.isEmpty
                ? "There's no voice called \(asked)."
                : "There's no voice called \(asked) — the ones I have are \(spokenList(known))."
        case .stored:
            return "Voice is \(voice). You'll hear it when you connect."
        case .reconnect:
            return "Voice is \(voice) — reconnecting so it starts fresh in the new voice."
        }
    }

    /// What the assistant says out loud when the change came from speech. Same facts as
    /// the transcript line, shorter, and in the first person — it is about to hang up on
    /// itself, so it says so.
    public static func spoken(_ plan: Plan, voice: String) -> String {
        switch plan {
        case .unchanged:
            return "I'm already using \(voice)."
        case .unknown(let asked):
            return asked.isEmpty
                ? "I didn't catch which voice you wanted."
                : "I don't have a voice called \(asked)."
        case .stored:
            return "Voice is \(voice). You'll hear it on the next session."
        case .reconnect:
            return "Switching to \(voice) — one moment while I reconnect."
        }
    }

    /// Whether this plan needs the socket taken down and brought back.
    public static func needsReconnect(_ plan: Plan) -> Bool { plan == .reconnect }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func spokenList(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
