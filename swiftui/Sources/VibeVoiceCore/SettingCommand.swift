import Foundation

/// Turning "make the background the ocean one" into a settings change.
///
/// Every one of these is already a control in a pane with six tabs and twenty-six
/// sections — which is fine until you are looking for one, at which point knowing it
/// exists is not the same as finding it. Saying what you want is faster than remembering
/// which tab it is on, and it is the interaction this app is for.
///
/// The parsing lives here because it is the part that can be wrong in ways worth testing:
/// a value that is not one of the choices, a name said three different ways, a number
/// outside its range.
public struct SettingChoice: Equatable, Sendable {
    /// What the model passes as `setting`.
    public let key: String
    /// What it is called out loud, for the confirmation. "the backdrop", "your voice".
    public let spoken: String
    /// Accepted values, lowercased, in the order a picker shows them. Empty for a
    /// switch or a number.
    public let values: [String]
    /// Other things the user might call it.
    public let aliases: [String]

    public init(key: String, spoken: String, values: [String] = [], aliases: [String] = []) {
        self.key = key
        self.spoken = spoken
        self.values = values
        self.aliases = aliases
    }
}

public enum SettingCommandError: Equatable, Sendable {
    case unknownSetting(String)
    case badValue(setting: String, given: String, allowed: [String])

    /// Written to be read aloud, and to say what to do instead. A tool that answers "no"
    /// without saying what would have worked makes the user guess at a list they cannot
    /// see.
    public var spoken: String {
        switch self {
        case .unknownSetting(let name):
            return "There's no setting called \(name)."
        case .badValue(let setting, let given, let allowed):
            let list = allowed.count <= 8
                ? allowed.joined(separator: ", ")
                : allowed.prefix(8).joined(separator: ", ") + ", and a few more"
            return "\(given) isn't one of the choices for \(setting). It can be \(list)."
        }
    }
}

public enum SettingCommand {

    /// Loose matching, because this arrives from speech.
    ///
    /// "Motion style", "motion", "the moving background" and "movingBackground" are one
    /// thing said four ways, and the model will pick whichever the user said rather than
    /// the key. Spaces, hyphens and case are all removed before comparing.
    public static func normalise(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Every name one setting answers to, normalised. "The" is dropped because people
    /// say "the wallpaper" and no setting is called that.
    static func names(of choice: SettingChoice) -> [String] {
        ([choice.key, choice.spoken] + choice.aliases)
            .map(normalise)
            .flatMap { $0.hasPrefix("the") && $0.count > 3 ? [$0, String($0.dropFirst(3))] : [$0] }
            .filter { !$0.isEmpty }
    }

    public static func find(_ name: String, in catalogue: [SettingChoice]) -> SettingChoice? {
        var n = normalise(name)
        if n.hasPrefix("the") && n.count > 3 { n = String(n.dropFirst(3)) }
        guard !n.isEmpty else { return nil }

        if let exact = catalogue.first(where: { names(of: $0).contains(n) }) { return exact }

        // Then containment, against every name rather than only the key — "wallpaper"
        // has to reach `backdrop` through its alias, not through its own spelling. Longest
        // first, so "camera size" beats "camera".
        return catalogue
            .sorted { normalise($0.key).count > normalise($1.key).count }
            .first { choice in
                names(of: choice).contains { $0.contains(n) || n.contains($0) }
            }
    }

    /// Matches a spoken value against the allowed ones.
    ///
    /// - Returns: the canonical value, or nil.
    public static func value(_ given: String, in choice: SettingChoice) -> String? {
        let g = normalise(given)
        guard !g.isEmpty else { return nil }

        // A switch. Everything a person says for yes and no, because "turn the widget on"
        // and "yes" and "please do" all arrive here as the value.
        if choice.values.isEmpty {
            let yes = ["on", "true", "yes", "enable", "enabled", "please", "yep", "yeah", "1"]
            let no = ["off", "false", "no", "disable", "disabled", "stop", "nope", "0"]
            if yes.contains(g) { return "on" }
            if no.contains(g) { return "off" }
            return nil
        }

        if let exact = choice.values.first(where: { normalise($0) == g }) { return exact }
        return choice.values.first { normalise($0).contains(g) || g.contains(normalise($0)) }
    }

    /// Resolves a whole request, or says what was wrong with it.
    public enum Resolved: Equatable, Sendable {
        case ok(SettingChoice, String)
        case failed(SettingCommandError)
    }

    public static func resolve(setting: String,
                               value spoken: String,
                               catalogue: [SettingChoice]) -> Resolved {
        guard let choice = find(setting, in: catalogue) else {
            return .failed(.unknownSetting(setting))
        }
        guard let v = value(spoken, in: choice) else {
            return .failed(.badValue(setting: choice.spoken,
                                     given: spoken,
                                     allowed: choice.values.isEmpty ? ["on", "off"] : choice.values))
        }
        return .ok(choice, v)
    }
}
