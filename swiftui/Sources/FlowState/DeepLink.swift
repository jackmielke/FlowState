import Foundation
import AppKit

/// `flowstate://` — the cold-start door.
///
/// A Carbon hotkey cannot fire in a process that does not exist, so a shortcut that has
/// to work with FlowState quit needs something else to catch the key. Anything that is
/// itself always running can: Shortcuts.app (a Quick Action with a keyboard shortcut),
/// Raycast, Alfred, Keyboard Maestro, or a plain `open flowstate://connect` from a
/// script. All of them do the same thing — hand LaunchServices a URL, which launches the
/// app if it is not running and delivers the URL either way.
///
/// So the deep link and the hotkey are deliberately the same action, not two similar
/// ones: `wakeAndConnect` is idempotent, and both routes call it.
enum DeepLink {
    /// The scheme in Info.plist. Kept here so the one place that parses it and the one
    /// place that documents it cannot drift.
    static let scheme = "flowstate"

    enum Action {
        /// Come forward, open the microphone, open a session. Idempotent.
        case connect
        /// Come forward and nothing else.
        case show
        /// Hang up and stay quiet.
        case hush

        init?(host: String?) {
            switch host?.lowercased() {
            case "connect", "wake", "listen": self = .connect
            case "show", "open", "summon":    self = .show
            case "hush", "stop", "sleep":     self = .hush
            default: return nil
            }
        }
    }

    /// A link that arrived before there was anything to act on it.
    ///
    /// On a cold start LaunchServices delivers the URL as part of launching, which can
    /// beat `AppState.init` — SwiftUI builds the delegate before it builds the scene's
    /// `@StateObject`. Dropping it there is the difference between "⌃Q launches Flow and
    /// connects" and "⌃Q launches Flow", which is the whole feature. Held here instead
    /// and drained by `AppState` once it exists.
    private static var pending: Action?

    /// - Returns: false if the URL was not ours, so the caller can leave it alone.
    @discardableResult
    @MainActor
    static func handle(_ url: URL) -> Bool {
        FileHandle.standardError.write(Data("[deeplink] \(url.absoluteString)\n".utf8))
        guard url.scheme?.lowercased() == scheme else { return false }
        guard let action = Action(host: url.host) else {
            FileHandle.standardError.write(Data(
                "[deeplink] ignoring \(url.absoluteString) — no such action\n".utf8))
            return false
        }
        if let state = AppState.current {
            perform(action, on: state)
        } else {
            pending = action
        }
        return true
    }

    /// Called once, by `AppState`, as soon as it can act.
    @MainActor
    static func drainPending(into state: AppState) {
        guard let action = pending else { return }
        pending = nil
        perform(action, on: state)
    }

    @MainActor
    private static func perform(_ action: Action, on state: AppState) {
        switch action {
        case .connect: state.wakeAndConnect(from: "url")
        case .show:    Summon.bringToFront()
        case .hush:    state.hush()
        }
    }
}
