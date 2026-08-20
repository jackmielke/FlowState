import SwiftUI
import AppKit

/// The user's theme choice. Persisted in `AppSettings`, so it survives relaunch.
///
/// `.system` is not a snapshot — it hands control back to macOS, which means the
/// app flips live when the desktop flips (Night Shift schedule, Control Centre,
/// System Settings › Appearance › Auto).
enum AppearanceMode: String, Codable, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }

    /// nil = no preference, i.e. whatever macOS is currently doing.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// nil lets the view/window inherit from `NSApp`, and `NSApp` from the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    /// ⌥⌘1/2/3 in the View menu. ⌘⇧2 is already the screenshot hotkey, hence ⌥.
    var shortcut: KeyEquivalent {
        switch self {
        case .system: return "1"
        case .light:  return "2"
        case .dark:   return "3"
        }
    }

    /// Order the one-click header control cycles through.
    var next: AppearanceMode {
        switch self {
        case .system: return .light
        case .light:  return .dark
        case .dark:   return .system
        }
    }

    /// SwiftUI's `.preferredColorScheme` only reaches views. This is what makes the
    /// menu bar, the sheet, the traffic lights and `NSVisualEffectView`'s material
    /// agree with it — and setting nil is what re-enables live system tracking.
    ///
    /// Deliberately *not* `@MainActor`: every caller is a SwiftUI `Binding` setter or a
    /// menu action, and a `Binding` setter is not itself actor-isolated. Isolating this
    /// would push the error onto those call sites, so it takes the main-thread
    /// guarantee from where it is actually called instead.
    func applyToApp() {
        let a = nsAppearance
        MainActor.assumeIsolated { NSApp.appearance = a }
    }
}
