import Foundation
import ServiceManagement
import AppKit

/// Whether FlowState starts itself when the Mac logs in.
///
/// WHY THIS IS PART OF THE WAKE KEY AND NOT A NICETY
/// `RegisterEventHotKey` binds a hotkey to a *running process*. There is no macOS
/// facility for "run this app when this key is pressed" — no LaunchServices hook, no
/// declarative plist, nothing. So a global shortcut that is supposed to work "even if
/// the app is not open" has exactly two honest implementations:
///
///   1. Make sure the app IS open. That is this file: register as a login item, keep
///      the process alive with no window (see `AppDelegate`), and the Carbon hotkey is
///      live from login until logout.
///   2. Let something that IS always running catch the key and launch us. That is the
///      `flowstate://` URL scheme — see `DeepLink`. Shortcuts.app, Raycast and Alfred
///      all keep a resident process and can be bound to a key, so they can cold-start
///      the app on a chord the app itself could never have heard.
///
/// Both ship. (1) is the one that makes ⌃Q feel instant; (2) is the one that survives a
/// deliberate Quit.
///
/// `SMAppService` needs a real bundle with a stable identifier — a bare SwiftPM binary
/// has neither, so `isAvailable` is false when run out of `.build` and the toggle in
/// Settings says so rather than failing silently.
enum LoginItem {

    /// False when running the raw executable rather than `FlowState.app`. Registering a
    /// login item from there would either throw or, worse, succeed and pin the login
    /// item to a path inside a build directory that the next `build.sh` deletes.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
            && Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// macOS may hold the registration in "awaiting approval" — the user has to allow it
    /// under General › Login Items. That is not a failure, but it is not `.enabled`
    /// either, and the difference is the whole reason the shortcut might not work
    /// tomorrow morning, so it gets its own answer rather than being folded into a Bool.
    static var needsApproval: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .requiresApproval
    }

    /// - Returns: nil on success, or something to put on a banner.
    @discardableResult
    static func setEnabled(_ on: Bool) -> String? {
        guard isAvailable else {
            return "Start at login needs the built app bundle — this is running the bare binary from .build."
        }
        do {
            if on {
                // Registering while already registered throws `kSMErrorAlreadyRegistered`
                // rather than being a no-op, and Settings can call this from a toggle
                // that is only *nearly* in sync with the system's idea of the state.
                guard SMAppService.mainApp.status != .enabled else { return nil }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "Could not \(on ? "enable" : "disable") Start at login: \(error.localizedDescription)"
        }
    }

    /// Opens the pane where the user approves it, for when `needsApproval` is true.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
