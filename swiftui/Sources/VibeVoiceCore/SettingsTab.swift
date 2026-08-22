import Foundation

/// The tabs Settings is divided into.
///
/// Nineteen headings in one scroll is a list you search rather than a place you know;
/// past about the fourth section nobody scrolls, they just stop finding things. The split
/// below is by the question being asked, not by which part of the code owns the setting —
/// "what does it look like" is one tab even though appearance, backdrop and motion are
/// three different subsystems.
///
/// Order is the order of the questions people arrive with: what is this thing, what does
/// it look like, what can it see, how do I reach it, what can it change, and what does it
/// keep.
public enum SettingsTab: String, CaseIterable, Identifiable, Codable, Sendable {
    case general, look, screen, access, dev, data

    public var id: String { rawValue }

    /// One word wherever one word will do — these sit under a 22-point icon in a strip
    /// that has to stay narrower than the pane.
    public var label: String {
        switch self {
        case .general: return "General"
        case .look:    return "Look"
        case .screen:  return "Screen"
        case .access:  return "Access"
        case .dev:     return "Dev"
        case .data:    return "Data"
        }
    }

    /// SF Symbol for the strip. All six are from the macOS 14 set.
    public var symbol: String {
        switch self {
        case .general: return "person.wave.2"
        case .look:    return "paintbrush"
        case .screen:  return "display"
        case .access:  return "menubar.arrow.up.rectangle"
        case .dev:     return "hammer"
        case .data:    return "lock.shield"
        }
    }

    /// The tooltip, and what VoiceOver reads after the name. Says what is *in* the tab —
    /// a label alone leaves "Access" and "Data" as guesses.
    public var blurb: String {
        switch self {
        case .general: return "Personality, voice, model, turn-taking and cost."
        case .look:    return "Appearance, backdrops, moving backgrounds and the floating widget."
        case .screen:  return "What it can see: permission, which display, how often."
        case .access:  return "Menu bar, summon shortcut, tools and connectors."
        case .dev:     return "Letting Claude Code change files on this Mac."
        case .data:    return "Recordings, conversations, what is kept and for how long."
        }
    }

    /// Restores a stored tab, falling back rather than trapping.
    ///
    /// The selection is persisted by raw string, so a build that renames or drops a tab
    /// would otherwise reopen Settings on nothing at all.
    public init(stored: String?) {
        self = SettingsTab(rawValue: stored ?? "") ?? .general
    }
}
