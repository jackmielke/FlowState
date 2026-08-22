import Foundation

/// What kind of thing a backdrop is, which is what the Look pane sorts them by.
///
/// Not a cosmetic grouping: each kind brings different controls with it — a place has an
/// hour of the day, a photo has a file and a rotation interval, and a moving backdrop has
/// a style, an intensity and a video loop. Asking "which kind" is how the pane knows what
/// to put underneath the grid.
public enum BackdropKind: String, Sendable, Equatable {
    /// A flat theme colour. Midnight and Paper.
    case flat
    /// One of the painted places.
    case place
    /// Something that moves. The style itself is a `MotionStyle`.
    case motion
    /// The user's own photo, or a folder of them.
    case photo
}

/// The scene behind the orb.
///
/// The identity half — the cases, what they are called and which kind each one is — lives
/// here rather than in the app target so the Look pane's two galleries can be stated as
/// facts and tested as facts. How each one is *painted* is SwiftUI's problem and stays in
/// `Backdrop.swift` beside the view that does it.
public enum Backdrop: String, Codable, CaseIterable, Identifiable, Sendable {
    case midnight, paper, bali, capeTown, sanFrancisco, alps, tokyo, sahara, motion, custom

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .midnight:      return "Midnight"
        case .paper:         return "Paper"
        case .bali:          return "Bali"
        case .capeTown:      return "Cape Town"
        case .sanFrancisco:  return "San Francisco"
        case .alps:          return "Alps"
        case .tokyo:         return "Tokyo"
        case .sahara:        return "Sahara"
        case .motion:        return "Motion"
        case .custom:        return "Your photo"
        }
    }

    public var kind: BackdropKind {
        switch self {
        case .midnight, .paper: return .flat
        case .bali, .capeTown, .sanFrancisco, .alps, .tokyo, .sahara: return .place
        case .motion:  return .motion
        case .custom:  return .photo
        }
    }

    /// Whether this backdrop is a picture rather than a flat theme colour.
    ///
    /// Three separate behaviours hang off this — the chrome is pinned dark, ambient mode
    /// has something to reveal, and `BackdropView` is used instead of the plain gradient —
    /// and all three used to test `place != nil`, which was the same question right up
    /// until a backdrop existed that is a scene without being a place.
    public var isScene: Bool { kind == .place || kind == .motion }

    /// Whether UI text should sit on a dark or light ground. Scenic presets are dark
    /// enough at the top that the existing light-on-dark type keeps working.
    public var prefersDarkText: Bool { self == .paper }

    /// The Look pane's **Still backdrops** gallery: everything that holds one picture.
    ///
    /// `.motion` is not in here and that is the point. It was a tenth tile in a single
    /// grid whose only job was to reveal a second grid below it, which meant the moving
    /// backdrops were a mode you had to switch into before you could see them. They have
    /// their own always-visible section now, so the tile that used to open it is gone and
    /// the backdrop it stood for is chosen by picking one of them.
    public static let stillBackdrops: [Backdrop] = allCases.filter { $0.kind != .motion }

    /// The Look pane's **Moving backgrounds** gallery. Every style, always.
    public static let movingBackgrounds: [MotionStyle] = MotionStyle.allCases
}

/// What the Look pane's two galleries are choosing between, and the rules for choosing.
///
/// A pair rather than two loose fields because the interesting behaviour is in how they
/// move together: the moving gallery writes both, the still gallery writes one and leaves
/// the other alone, and "is this tile selected" is a question about both at once. Kept
/// out of the view so those three rules can be proved without a window.
public struct LookSelection: Equatable, Sendable {
    /// The backdrop actually on screen.
    public var backdrop: Backdrop
    /// Which moving background `.motion` shows — and which one is remembered while a
    /// still backdrop is up, so coming back to the moving section returns to it.
    public var motionStyle: MotionStyle

    public init(backdrop: Backdrop, motionStyle: MotionStyle) {
        self.backdrop = backdrop
        self.motionStyle = motionStyle
    }

    /// Whether the Still gallery's tile for `backdrop` is the current choice.
    public func isShowing(_ backdrop: Backdrop) -> Bool { self.backdrop == backdrop }

    /// Whether the Moving gallery's tile for `style` is the current choice.
    ///
    /// Both halves have to agree: a style that is merely remembered is not on screen, and
    /// ringing its tile while a photo is up would be a lie about what you are looking at.
    public func isShowing(_ style: MotionStyle) -> Bool {
        backdrop == .motion && motionStyle == style
    }

    /// Picks a still backdrop.
    ///
    /// The moving style is deliberately left as it was: it is not what you just chose, and
    /// clearing it would lose the one bit of state that lets the moving section come back
    /// up on the style you last liked.
    public mutating func choose(_ backdrop: Backdrop) {
        self.backdrop = backdrop
    }

    /// Picks a moving background.
    ///
    /// Always switches the backdrop to `.motion`, whatever was showing before. This is the
    /// whole of the old bug: when the moving grid only set the style, a click while a
    /// still backdrop was up changed a value nothing was reading and the tile appeared to
    /// do nothing. A gallery that is always on screen has to be a complete choice.
    public mutating func choose(_ style: MotionStyle) {
        motionStyle = style
        backdrop = .motion
    }
}
