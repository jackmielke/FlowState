import Foundation
import CoreGraphics

/// How big the floating camera is — the sizes Loom offers, under names that mean
/// something at a glance rather than pixel counts.
///
/// `full` is not a size in the same sense as the other three: it means the camera stops
/// being an inset and becomes the picture. It lives in the same enum anyway because it
/// is the same control in the UI, one row of four, and a user who wants their face large
/// keeps pressing the same button until it is as large as it goes.
public enum CameraSize: String, Codable, CaseIterable, Sendable, Identifiable {
    case small, medium, large, full

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        case .full:   return "Full"
        }
    }

    /// The bubble's diameter on screen, in points.
    public var diameter: CGFloat {
        switch self {
        case .small:  return 120
        case .medium: return 180
        case .large:  return 260
        // Full screen is not a bubble at all, but the panel still has to be *some* size
        // while the user is choosing; it shows what will fill the frame.
        case .full:   return 300
        }
    }

    /// How much of the recorded frame's width the camera takes.
    ///
    /// These are deliberately not `diameter / screenWidth`: the bubble is sized for a
    /// person looking at a 15-inch laptop from two feet away, and the recording is sized
    /// for someone watching it in a browser window. Tying them to the same number makes
    /// one of the two wrong.
    public var frameFraction: CGFloat {
        switch self {
        case .small:  return 0.14
        case .medium: return 0.20
        case .large:  return 0.28
        case .full:   return 1.0
        }
    }

    public var isFullFrame: Bool { self == .full }
}

/// The camera's outline. Loom offers a circle and a rounded rectangle; the difference
/// is not decoration — a circle crops hard to the centre of the frame, which flatters a
/// face and throws away the room, and a rectangle keeps what you are gesturing at.
public enum CameraShape: String, Codable, CaseIterable, Sendable, Identifiable {
    case circle, rounded, square

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .circle:  return "Circle"
        case .rounded: return "Rounded"
        case .square:  return "Square"
        }
    }

    /// Corner radius as a fraction of the shorter side.
    public var cornerFraction: CGFloat {
        switch self {
        case .circle:  return 0.5
        case .rounded: return 0.18
        case .square:  return 0
        }
    }
}

/// Which corner of the recording the camera sits in.
public enum CameraCorner: String, Codable, CaseIterable, Sendable {
    case bottomLeading, bottomTrailing, topLeading, topTrailing
}

/// One description of the camera overlay, used by both the floating bubble and the
/// composite that goes into the movie.
///
/// It exists because those two were described separately and drifted: the bubble was a
/// circle you could park anywhere, and the recording was a square pinned to the bottom
/// right, so what you framed was never what you got. Anything that decides how the
/// camera looks belongs here, and both sides read it.
public struct CameraOverlay: Equatable, Sendable {
    public var size: CameraSize
    public var corner: CameraCorner
    public var shape: CameraShape

    public init(size: CameraSize = .medium,
                corner: CameraCorner = .bottomTrailing,
                shape: CameraShape = .circle) {
        self.size = size
        self.corner = corner
        self.shape = shape
    }

    /// Whether the inset needs masking at all. A square one does not.
    public var isMasked: Bool { shape != .square }

    /// Margin from the frame edge, as a fraction of frame width.
    public static let marginFraction: CGFloat = 0.02

    /// Where the camera goes in a recorded frame.
    ///
    /// In Core Image coordinates — origin bottom-left — because that is what the
    /// compositor works in, and converting at the call site is how the overlay ends up
    /// vertically mirrored in one of the four corners and nobody notices for a week.
    ///
    /// Always square, so a circular mask is a circle rather than an ellipse: the camera
    /// is centre-cropped to fit rather than squashed into it.
    public func rect(in frame: CGSize) -> CGRect {
        guard !size.isFullFrame else {
            return CGRect(origin: .zero, size: frame)
        }
        let side = frame.width * size.frameFraction
        let margin = frame.width * Self.marginFraction
        let x: CGFloat
        let y: CGFloat
        switch corner {
        case .bottomLeading:  x = margin;                       y = margin
        case .bottomTrailing: x = frame.width - side - margin;  y = margin
        case .topLeading:     x = margin;                       y = frame.height - side - margin
        case .topTrailing:    x = frame.width - side - margin;  y = frame.height - side - margin
        }
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// The corner of `bounds` that `point` is nearest — how the bubble's parking spot
    /// becomes the recording's corner without asking the user the same question twice.
    ///
    /// `bounds` and `point` are both in screen coordinates with the origin at the
    /// bottom left, which is what AppKit gives for a window's frame.
    public static func nearestCorner(to point: CGPoint, in bounds: CGRect) -> CameraCorner {
        let left = point.x < bounds.midX
        let bottom = point.y < bounds.midY
        switch (left, bottom) {
        case (true, true):   return .bottomLeading
        case (false, true):  return .bottomTrailing
        case (true, false):  return .topLeading
        case (false, false): return .topTrailing
        }
    }
}

public extension CameraCorner {
    /// Named the way somebody would say it out loud, for a settings caption.
    var blurb: String {
        switch self {
        case .bottomLeading:  return "bottom left"
        case .bottomTrailing: return "bottom right"
        case .topLeading:     return "top left"
        case .topTrailing:    return "top right"
        }
    }
}
