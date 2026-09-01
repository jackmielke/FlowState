import Foundation

/// One shortcut as the user has it set: what it does, and which chord it is on.
///
/// The app target owns the chords themselves — they are Carbon key codes and cannot be
/// described without `Carbon.HIToolbox` — so what crosses into Core is the pair of
/// strings the conflict rules actually need. `role` is the wording from the Settings
/// pane ("Wake it up"), because every message built here is read by somebody looking at
/// that pane and a second vocabulary for the same row helps nobody.
public struct HotkeyBinding: Equatable, Sendable {
    /// The Settings row this shortcut belongs to, in that row's own words.
    public let role: String
    /// Stable identifier of the chord, e.g. `"ctrlQ"`. Empty means the row is off.
    public let comboID: String
    /// How the chord is written for a human, e.g. `"⌃Q"`.
    public let label: String

    public init(role: String, comboID: String, label: String) {
        self.role = role
        self.comboID = comboID
        self.label = label
    }
}

/// Two shortcuts asking for the same chord.
public struct HotkeyClash: Equatable, Sendable {
    public let comboID: String
    public let label: String
    /// Every role set to this chord, in the order they were given.
    public let roles: [String]

    /// Deliberately does not name a winner.
    ///
    /// macOS hands a chord to whichever registration got there first, and "first" here
    /// means the order the app happened to bind its slots in — startup order on launch,
    /// but edit order once somebody has been changing settings. Naming a winner would be
    /// a guess dressed up as a fact, and the user does not need one: what they need to
    /// know is that one of these two rows is dead, and that the fix is a different key.
    public var message: String {
        let list = roles.joined(separator: " and ")
        return "\(label) is set for both \(list). macOS gives a chord to one owner, so one of them will not fire — put them on different keys."
    }
}

/// What can go wrong with a keyboard shortcut before anybody presses it, and how to say
/// so out loud.
///
/// Three separate failures live here, and they are worth keeping separate because the
/// user can only act on the third one blind:
///
///  1. **Two of our own rows on one chord.** Detectable from settings alone, the moment
///     the second row is picked — see `clashes(among:)`.
///  2. **Another app already owns it.** Only knowable at registration time, from the
///     `OSStatus` that `RegisterEventHotKey` hands back — see `refused(role:label:)`.
///  3. **Nothing is broken, but the chord means something else somewhere.** ⌃Q stops
///     being XON in every terminal on the machine the moment it is bound here. Nothing
///     reports that, ever; it is simply true — see `advisory(for:)`.
public enum HotkeyConflict {

    /// Rows that have been given the same chord as another row.
    ///
    /// Empty `comboID`s are dropped: "off" is not a chord, and three rows switched off
    /// are not three rows fighting over nothing.
    public static func clashes(among bindings: [HotkeyBinding]) -> [HotkeyClash] {
        var order: [String] = []
        var byCombo: [String: [HotkeyBinding]] = [:]
        for b in bindings where !b.comboID.isEmpty {
            if byCombo[b.comboID] == nil { order.append(b.comboID) }
            byCombo[b.comboID, default: []].append(b)
        }
        return order.compactMap { id in
            guard let group = byCombo[id], group.count > 1 else { return nil }
            return HotkeyClash(comboID: id, label: group[0].label, roles: group.map(\.role))
        }
    }

    /// The clash affecting one row, for the warning printed under that row's picker.
    public static func clash(for role: String, among bindings: [HotkeyBinding]) -> HotkeyClash? {
        clashes(among: bindings).first { $0.roles.contains(role) }
    }

    /// What to say when macOS refused the registration.
    ///
    /// The status code is left out on purpose. `-9878` tells the user nothing they can
    /// act on, and the one thing they can act on — pick another key — fits in a line.
    public static func refused(role: String, label: String) -> String {
        "\(label) could not be registered for \(role) — another app already owns it. Pick a different key."
    }

    /// What that chord already means elsewhere, for chords where the answer is "quite a
    /// lot".
    ///
    /// Only the ones somebody will actually notice losing. A note under every option
    /// would be noise, and noise is how the one that matters gets skipped.
    public static func advisory(for comboID: String) -> String? {
        switch comboID {
        case "ctrlQ":
            return "⌃Q is also XON in a terminal — the key that resumes output after ⌃S. Binding it here takes it from Terminal, iTerm and tmux, so pick ⌃⇧Q or ⌃⌥Space instead if you use flow control."
        case "escape":
            return "Escape means \"cancel\" in every app there is, so it is only listened for while a session is actually live and FlowState is not the app in front. The rest of the time Escape is nobody's but yours."
        case "optionSpace":
            return "⌥Space is a common launcher key — Alfred and Raycast both ship it as a default. If one of those has it, this one will not fire."
        default:
            return nil
        }
    }
}

/// When a shortcut with no modifier on it is allowed to be listening.
///
/// Escape is the case, and the rule is two lines of boolean that are very easy to get
/// backwards — so it lives here, where it can be stated once and tested, rather than
/// inside an `if` in the middle of the app's hotkey plumbing. Getting it wrong in either
/// direction is bad in a different way: too generous and Escape stops cancelling things
/// across the whole Mac, too shy and the deactivate key silently does nothing at the
/// moment somebody needs it most.
public enum SessionScopedHotkey {

    /// True when a modifier-less chord should currently be registered process-wide.
    ///
    /// - Parameters:
    ///   - sessionLive: a session is open or opening. Nothing to deactivate otherwise,
    ///     and holding the key for a state that does not exist is pure theft.
    ///   - appIsFrontmost: our own window is the one in front. Carbon registers ahead of
    ///     every app *including this one*, so binding here would take Escape away from
    ///     our own "cancel this edit" and "close this panel" — a key doing the wrong
    ///     thing in the one place the user can see us.
    public static func shouldBind(sessionLive: Bool, appIsFrontmost: Bool) -> Bool {
        sessionLive && !appIsFrontmost
    }
}
