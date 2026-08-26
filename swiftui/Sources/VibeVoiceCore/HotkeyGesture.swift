import Foundation

/// One key, two meanings: hold it to dictate, press it twice to start talking.
///
/// Overloading a single hotkey is worth doing here because the two modes are the same
/// intention at different lengths — "take what I say" — and a second shortcut is a second
/// thing to remember. It is worth doing *carefully* because the two gestures overlap in
/// their first few milliseconds: every double press begins as a press that might become a
/// hold, and every hold begins as a press that might become a double press.
///
/// The rules that fall out of that, in the order they matter:
///
///  1. A press does not mean anything until it has been held past `holdThreshold` or
///     released. Acting on key-down would start dictation on the first half of every
///     double press.
///  2. Only *taps* count toward a double press. Hold, release, press again quickly is two
///     separate intentions — dictating and then opening voice mode — not a double press.
///  3. A lone tap does nothing. It is the gesture a user makes by accident, and the
///     recognizer waits out the double-press window before discarding it rather than
///     firing something they did not ask for.
///
/// Deterministic on purpose: the caller supplies every timestamp and drives `tick`, so the
/// whole thing can be tested without sleeping. `HotkeyGestureDriver` in the app target owns
/// the real clock.
public enum HotkeyGesture: Equatable, Sendable {

    /// What the recognizer decided the user meant.
    public enum Action: Equatable, Sendable {
        /// The key has been down past the threshold — open the mic and start dictating.
        case beginDictation
        /// The key came up while dictating — close the mic, transcribe, insert.
        case endDictation
        /// Two quick taps — open the full voice-to-voice session.
        case startVoiceMode
        /// A single tap while a session is running — hang up.
        case stopVoiceMode
        /// A hold was abandoned before anything was captured; undo any UI the begin showed.
        case cancelDictation
    }

    /// The recognizer's own view of what is happening.
    private enum Phase: Equatable {
        /// Nothing pressed, nothing pending.
        case idle
        /// Key is down; not yet held long enough to be a hold.
        case pressed(since: TimeInterval)
        /// Key is down and past the threshold — dictation is running.
        case holding
        /// A tap has completed and we are waiting to see if a second one arrives.
        case awaitingSecondTap(firstTapEndedAt: TimeInterval)
    }

    public struct Recognizer: Sendable {

        /// How long the key must be down before it counts as a hold rather than a tap.
        ///
        /// 250ms is deliberately near the top of "instant". Shorter and a deliberate
        /// double press starts leaking into dictation; longer and holding the key feels
        /// like it is ignoring you.
        public var holdThreshold: TimeInterval

        /// How long after a tap a second tap still counts as a double press.
        public var doubleTapWindow: TimeInterval

        /// Whether a voice-to-voice session is currently running. The driver keeps this in
        /// sync with the connection state.
        ///
        /// This is what makes a single tap safe to act on. While nothing is running a tap
        /// is ambiguous — it might be the first half of a double press — so it has to wait
        /// out the window and then be discarded. While a session *is* running that
        /// ambiguity disappears, because a double press could only mean "start" and it has
        /// already started. So a tap can hang up the moment the key comes up, with none of
        /// the 350ms delay that would make hanging up feel broken.
        public var isVoiceModeActive: Bool = false

        private var phase: Phase = .idle

        public init(holdThreshold: TimeInterval = 0.25, doubleTapWindow: TimeInterval = 0.35) {
            self.holdThreshold = holdThreshold
            self.doubleTapWindow = doubleTapWindow
        }

        /// True while dictation is actually running, for the widget's indicator.
        public var isDictating: Bool { phase == .holding }

        /// The next moment `tick` needs to be called, if any.
        ///
        /// The driver uses this to schedule a single timer rather than polling. Returning
        /// nil means nothing is pending and no timer is needed.
        public var nextDeadline: TimeInterval? {
            switch phase {
            case .pressed(let since):               return since + holdThreshold
            case .awaitingSecondTap(let endedAt):   return endedAt + doubleTapWindow
            case .idle, .holding:                   return nil
            }
        }

        /// The hotkey went down.
        public mutating func keyDown(at now: TimeInterval) -> Action? {
            switch phase {
            case .awaitingSecondTap(let endedAt) where now - endedAt <= doubleTapWindow:
                // Rule 2 is already satisfied here: we only ever reach this phase from a
                // tap, never from a hold.
                phase = .idle
                return .startVoiceMode

            case .idle, .awaitingSecondTap:
                phase = .pressed(since: now)
                return nil

            case .pressed, .holding:
                // Key repeat, or a down without a matching up. Ignore rather than
                // restarting the clock, which would make a long hold never fire.
                return nil
            }
        }

        /// The hotkey came up.
        public mutating func keyUp(at now: TimeInterval) -> Action? {
            switch phase {
            case .holding:
                phase = .idle
                return .endDictation

            case .pressed where isVoiceModeActive:
                // Nothing to disambiguate: a session is already open, so this tap can only
                // mean hang up. Acting now rather than after the double-press window is
                // the difference between a stop key that feels instant and one that feels
                // stuck.
                phase = .idle
                return .stopVoiceMode

            case .pressed:
                // A tap with nothing running. Do not act yet — it might be the first half
                // of a double press.
                phase = .awaitingSecondTap(firstTapEndedAt: now)
                return nil

            case .idle, .awaitingSecondTap:
                return nil
            }
        }

        /// Time passed. Called when `nextDeadline` arrives.
        public mutating func tick(at now: TimeInterval) -> Action? {
            switch phase {
            case .pressed(let since) where now - since >= holdThreshold:
                phase = .holding
                return .beginDictation

            case .awaitingSecondTap(let endedAt) where now - endedAt >= doubleTapWindow:
                // Rule 3: the second tap never came. A lone tap means nothing.
                phase = .idle
                return nil

            default:
                return nil
            }
        }

        /// Give up on whatever is in flight — app resigned active, hotkey rebound, screen
        /// locked. Reports whether dictation was interrupted so the caller can tear down.
        public mutating func reset() -> Action? {
            let wasHolding = phase == .holding
            phase = .idle
            return wasHolding ? .cancelDictation : nil
        }
    }
}
