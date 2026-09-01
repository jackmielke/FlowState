import Foundation

/// One key, two meanings: hold it to dictate, tap it once to toggle voice mode.
///
/// Overloading a single hotkey is worth doing here because the two modes are the same
/// intention at different lengths — "take what I say" — and a second shortcut is a second
/// thing to remember. It is worth doing *carefully* because the two gestures overlap in
/// their first few milliseconds: every tap begins as a press that might become a hold.
///
/// The rules that fall out of that, in the order they matter:
///
///  1. A press does not mean anything until it has been held past `holdThreshold` or
///     released. Acting on key-down would start dictation on the way to every tap.
///  2. A tap resolves the instant the key comes up: start if nothing is running, stop if
///     something is. Nothing waits on a second press — one tap, one toggle, no lag.
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
        /// A tap while nothing is running — open the full voice-to-voice session.
        case startVoiceMode
        /// A tap while a session is running — hang up.
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
    }

    public struct Recognizer: Sendable {

        /// How long the key must be down before it counts as a hold rather than a tap.
        ///
        /// 250ms is deliberately near the top of "instant". Shorter and a deliberate tap
        /// starts leaking into dictation; longer and holding the key feels like it is
        /// ignoring you.
        public var holdThreshold: TimeInterval

        /// Whether a voice-to-voice session is currently running. The driver keeps this in
        /// sync with the connection state.
        ///
        /// This is what a tap toggles: start it when this is false, stop it when this is
        /// true. There is no window to wait out — a single press is unambiguous either
        /// way, so the key can act the instant it comes back up.
        public var isVoiceModeActive: Bool = false

        private var phase: Phase = .idle

        public init(holdThreshold: TimeInterval = 0.25) {
            self.holdThreshold = holdThreshold
        }

        /// True while dictation is actually running, for the widget's indicator.
        public var isDictating: Bool { phase == .holding }

        /// The next moment `tick` needs to be called, if any.
        ///
        /// The driver uses this to schedule a single timer rather than polling. Returning
        /// nil means nothing is pending and no timer is needed.
        public var nextDeadline: TimeInterval? {
            switch phase {
            case .pressed(let since): return since + holdThreshold
            case .idle, .holding:     return nil
            }
        }

        /// The hotkey went down.
        public mutating func keyDown(at now: TimeInterval) -> Action? {
            switch phase {
            case .idle:
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

            case .pressed:
                // A tap. Nothing to disambiguate — one press is one toggle — so it acts
                // immediately rather than waiting on a second press that never mattered.
                phase = .idle
                return isVoiceModeActive ? .stopVoiceMode : .startVoiceMode

            case .idle:
                return nil
            }
        }

        /// Time passed. Called when `nextDeadline` arrives.
        public mutating func tick(at now: TimeInterval) -> Action? {
            switch phase {
            case .pressed(let since) where now - since >= holdThreshold:
                phase = .holding
                return .beginDictation

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
