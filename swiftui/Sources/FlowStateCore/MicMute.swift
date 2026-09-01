import Foundation

/// Muting the microphone: where a captured chunk is allowed to go, and what the button
/// that decides it says.
///
/// Mute is not "turn the level down". Three different consumers sit on the capture path —
/// the socket, the utterance meter and the session recorder — and they want three
/// different things from a mute, so the decision is made once, here, rather than three
/// times at three call sites that can drift apart:
///
///  * **The model must not hear it.** That is the whole point, and it is the one part
///    that is a privacy promise rather than a preference.
///  * **The meter must read dead, not quiet.** An orb that keeps reacting while muted is
///    an app that looks like it is still listening, which is worse than no indicator.
///  * **The recorder must keep getting frames.** The microphone is the recording's clock —
///    see `SessionRecorder.appendMic` — so withholding chunks while muted would stall the
///    timeline and pile the model's replies on top of each other in the file. It gets
///    silence of exactly the same length instead, which is both an honest record of a
///    muted stretch and a timeline that stays sample-accurate.
public enum MicMute {

    /// What one chunk of captured microphone audio may do.
    public struct Route: Equatable, Sendable {
        /// Goes onto the socket. The only field that is a promise to the user.
        public let toModel: Bool
        /// Measured by `UtteranceRecorder` for the transcript's audio metadata.
        public let toMeasurement: Bool
        /// Reaches `SessionRecorder`. Always true — it is the recording's clock.
        public let toRecorder: Bool
        /// Written as digital silence rather than as what the microphone heard.
        public let silenced: Bool

        public init(toModel: Bool, toMeasurement: Bool, toRecorder: Bool, silenced: Bool) {
            self.toModel = toModel
            self.toMeasurement = toMeasurement
            self.toRecorder = toRecorder
            self.silenced = silenced
        }
    }

    /// The routing rule. `connected` is the socket, not the mute — a chunk captured
    /// while the session is down has nowhere to be sent either way.
    public static func route(muted: Bool, connected: Bool) -> Route {
        Route(toModel: !muted && connected,
              toMeasurement: !muted,
              toRecorder: true,
              silenced: muted)
    }

    /// A chunk of the same length, all zeroes.
    ///
    /// Same length is the load-bearing part: the recorder advances its cursor by whatever
    /// it is handed, so a shorter substitute would make a muted minute occupy less than a
    /// minute of the file and slide everything after it earlier.
    public static func silence(like chunk: Data) -> Data {
        Data(count: chunk.count)
    }

    // MARK: - What the control says

    /// SF Symbol for the button. Slashed when muted: the strike-through is the one mic
    /// glyph nobody has to learn.
    public static func symbol(muted: Bool) -> String {
        muted ? "mic.slash.fill" : "mic.fill"
    }

    /// The word next to it, where there is room for one.
    public static func label(muted: Bool) -> String {
        muted ? "Muted" : "Mic on"
    }

    /// Tooltip and VoiceOver hint. Says what clicking does, not what the state is — the
    /// state is already on screen, and a tooltip that repeats it is a tooltip that
    /// answers the question nobody asked.
    public static func help(muted: Bool, live: Bool) -> String {
        if muted {
            return live
                ? "Unmute — the microphone is off and nothing is reaching the model."
                : "Unmute. The microphone will stay off until you do, even after a restart."
        }
        return live
            ? "Mute the microphone. The session stays open and the model stops hearing you."
            : "Mute the microphone before the next session starts."
    }

    /// What goes in the transcript when the user flips it, so a silent stretch in a
    /// recording has an explanation next to it rather than looking like a fault.
    public static func note(muted: Bool) -> String {
        muted
            ? "Microphone muted — nothing is being sent until it is unmuted."
            : "Microphone unmuted."
    }
}
