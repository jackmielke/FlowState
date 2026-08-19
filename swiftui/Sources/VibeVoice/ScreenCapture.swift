import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit
import UniformTypeIdentifiers

struct CapturedFrame {
    let dataURI: String     // data:image/jpeg;base64,...
    let thumbnail: NSImage
    let bytes: Int
}

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noDisplay
    case encodeFailed
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is not granted for Vibe Voice."
        case .noDisplay: return "No display found to capture."
        case .encodeFailed: return "Could not JPEG-encode the captured frame."
        case .underlying(let s): return s
        }
    }
}

/// ScreenCaptureKit path — CGWindowListCreateImage is deprecated on macOS 26.
enum ScreenCapture {

    static func hasPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    static func openPrivacySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(u)
        }
    }

    static func capture(maxWidth: CGFloat = 1280, quality: CGFloat = 0.7) async throws -> CapturedFrame {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            let ns = error as NSError
            // SCStream errors around -3801 / -3803 are the TCC denial family.
            if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" || ns.code == -3801 {
                throw ScreenCaptureError.permissionDenied
            }
            throw ScreenCaptureError.underlying(ns.localizedDescription)
        }

        // Prefer the display holding the key window; fall back to the first.
        let target: SCDisplay
        if let main = NSScreen.main,
           let num = main.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let match = content.displays.first(where: { $0.displayID == num.uint32Value }) {
            target = match
        } else if let first = content.displays.first {
            target = first
        } else {
            throw ScreenCaptureError.noDisplay
        }

        let filter = SCContentFilter(display: target, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        let scale = min(1.0, maxWidth / CGFloat(target.width))
        cfg.width = Int((CGFloat(target.width) * scale).rounded())
        cfg.height = Int((CGFloat(target.height) * scale).rounded())
        cfg.scalesToFit = true
        cfg.showsCursor = true
        cfg.captureResolution = .best

        let cg: CGImage
        do {
            cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            throw ScreenCaptureError.underlying((error as NSError).localizedDescription)
        }

        guard let jpeg = jpegData(from: cg, quality: quality) else { throw ScreenCaptureError.encodeFailed }
        let uri = "data:image/jpeg;base64," + jpeg.base64EncodedString()
        let thumb = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        return CapturedFrame(dataURI: uri, thumbnail: thumb, bytes: jpeg.count)
    }

    private static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
