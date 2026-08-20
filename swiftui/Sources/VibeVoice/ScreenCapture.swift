import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit
import UniformTypeIdentifiers
import os

struct CapturedFrame {
    let dataURI: String     // data:image/jpeg;base64,...
    let thumbnail: NSImage
    let bytes: Int
}

/// What macOS will let *this process* do right now.
///
/// `.granted` and `.denied` are not enough, because TCC and ScreenCaptureKit can
/// disagree: macOS latches the screen-recording decision into a process the first
/// time it asks, so a process that was refused stays refused for its whole life
/// even after the user flips the toggle on. Reporting that as "permission is off"
/// is the false negative — the permission IS on, the process is just stale.
enum ScreenPermission: Equatable {
    /// TCC says yes and nothing in this process contradicts it.
    case granted
    /// TCC says no. The user has to grant it.
    case denied
    /// TCC says yes, but this process was refused and will keep being refused
    /// until it is relaunched.
    case needsRestart
    /// Not checked yet.
    case unknown

    var canCapture: Bool { self == .granted }
    var blocksCapture: Bool { self == .denied || self == .needsRestart }

    var title: String {
        switch self {
        case .granted:      return "Screen Recording is on"
        case .denied:       return "Screen Recording is off"
        case .needsRestart: return "Screen Recording is on — relaunch to use it"
        case .unknown:      return "Screen Recording state unknown"
        }
    }

    /// One line for the banner. The card in ContentView says more.
    var bannerText: String {
        switch self {
        case .granted:      return "Screen Recording is on for Vibe Voice."
        case .denied:       return "Screen Recording is off for Vibe Voice — turn it on in System Settings."
        case .needsRestart: return "Screen Recording is granted, but Vibe Voice must be relaunched to pick it up."
        case .unknown:      return "Could not determine Screen Recording permission."
        }
    }

    /// Short, greppable token for the log.
    var logToken: String {
        switch self {
        case .granted: return "granted"
        case .denied: return "denied"
        case .needsRestart: return "needs-restart"
        case .unknown: return "unknown"
        }
    }
}

enum ScreenCaptureError: LocalizedError {
    case permissionDenied(ScreenPermission)
    case noDisplay
    case encodeFailed
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let p): return p.bannerText
        case .noDisplay: return "No display found to capture."
        case .encodeFailed: return "Could not JPEG-encode the captured frame."
        case .underlying(let s): return s
        }
    }
}

/// ScreenCaptureKit path — CGWindowListCreateImage is deprecated on macOS 26.
///
/// Main-actor isolated because the per-process permission evidence below is
/// mutable shared state, and every caller (AppState, the permission card) is
/// already on the main actor.
@MainActor
enum ScreenCapture {

    private static let logger = Logger(subsystem: "com.jackmielke.vibevoice", category: "screen-permission")

    // MARK: - Per-process evidence
    //
    // `CGPreflightScreenCaptureAccess()` reads the TCC decision, which is a
    // machine-wide fact. Whether SCK will actually hand this process a frame is a
    // per-process fact. Both are tracked so the two can be told apart, which is
    // the whole point: TCC=yes + SCK=no means "relaunch", not "off".

    /// Set once SCK has actually produced content in this process.
    private static var everCaptured = false
    /// Set when SCK refused this process with a TCC-family error.
    private static var refusedInProcess = false
    /// CGRequestScreenCaptureAccess only ever prompts once; don't re-block on it.
    private static var didRequest = false
    /// Suppresses identical back-to-back state lines in the log.
    private static var lastLoggedState: ScreenPermission?

    private static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("[screen] \(message)\n".utf8))
    }

    // MARK: - Reading permission

    /// Live TCC read. Never prompts, never blocks — safe to call as often as you like.
    static func preflight() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Resolves TCC's answer against what this process has actually observed.
    ///
    /// Deliberately biased against false negatives: a successful capture in this
    /// process outranks a preflight that says no, because preflight is the value
    /// that can go stale, not a frame we are holding in our hands.
    static func status() -> ScreenPermission {
        let tcc = preflight()
        if refusedInProcess {
            // SCK said no to *us*. If TCC says yes, the grant landed after we
            // launched and only a relaunch will pick it up.
            return tcc ? .needsRestart : .denied
        }
        if tcc { return .granted }
        return everCaptured ? .granted : .denied
    }

    /// Re-reads permission and logs it. Call this on launch, on app activation,
    /// before a capture, and whenever the user asks.
    @discardableResult
    static func refresh(reason: String) -> ScreenPermission {
        let tcc = preflight()
        let state = status()
        let changed = lastLoggedState != state
        lastLoggedState = state
        // Always log the refresh itself (that is the point of it); include the raw
        // inputs so a support log shows *why* the state resolved the way it did.
        log("refresh(\(reason)) -> \(state.logToken)"
            + " [preflight=\(tcc) refusedInProcess=\(refusedInProcess) everCaptured=\(everCaptured)]"
            + (changed ? " CHANGED" : ""))
        return state
    }

    /// Preflight, and if we have never been granted, fire the system prompt once.
    ///
    /// `CGRequestScreenCaptureAccess()` matters even when it returns false: it is
    /// what registers the app in Privacy & Security › Screen & System Audio
    /// Recording. Without it a first-run user opens that pane and finds no
    /// "Vibe Voice" row to toggle at all.
    static func ensureAccess(reason: String) async -> ScreenPermission {
        var state = refresh(reason: reason)
        guard state != .granted else { return state }
        // A stale process cannot be rescued by prompting — only by relaunching.
        guard state != .needsRestart else { return state }
        guard !didRequest else { return state }
        didRequest = true

        log("requesting access via CGRequestScreenCaptureAccess()…")
        // Blocks its thread while the system prompt is up, so keep it off main.
        let granted = await Task.detached(priority: .userInitiated) {
            CGRequestScreenCaptureAccess()
        }.value
        log("CGRequestScreenCaptureAccess() returned \(granted)")

        state = refresh(reason: "post-request")
        return state
    }

    /// Asks SCK directly, which is the only ground truth for "can this process
    /// capture". Cheap enough to run from a Check-again button.
    @discardableResult
    static func probe(reason: String) async -> ScreenPermission {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            noteCaptureSucceeded()
        } catch {
            _ = classify(error as NSError)
        }
        return refresh(reason: "probe(\(reason))")
    }

    static func openPrivacySettings() {
        log("opening Privacy & Security › Screen & System Audio Recording")
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(u)
        }
    }

    /// Relaunches the bundle, which is the only way to clear `.needsRestart`.
    static func relaunch() {
        let url = Bundle.main.bundleURL
        log("relaunching \(url.path) to pick up the new permission")
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
            let failure = error?.localizedDescription
            Task { @MainActor in
                if let failure {
                    log("relaunch failed: \(failure)")
                    return
                }
                // Only quit once the replacement is actually up.
                try? await Task.sleep(nanoseconds: 400_000_000)
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Error classification

    private static let scStreamErrorDomain = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
    /// The only two SCStreamError codes that mean TCC said no:
    /// `.userDeclined` (-3801) and `.missingEntitlements` (-3803). Everything else
    /// in that domain is a transient capture failure — window vanished, stream
    /// started too fast, no display list — and must NOT be reported as
    /// "Screen Recording is off", which is what the old catch-the-whole-domain
    /// check did.
    private static let tccDenialCodes: Set<Int> = [-3801, -3803]

    private static func noteCaptureSucceeded() {
        let wasRefused = refusedInProcess
        everCaptured = true
        refusedInProcess = false
        if wasRefused { log("capture succeeded after an earlier refusal — clearing stale denial") }
    }

    /// Turns an SCK error into the right `ScreenCaptureError`, updating the
    /// per-process evidence on the way through.
    private static func classify(_ ns: NSError) -> ScreenCaptureError {
        let isTCCCode = ns.domain == scStreamErrorDomain && tccDenialCodes.contains(ns.code)
        // Belt and braces: any failure while TCC says no is a permission problem,
        // whatever code SCK chose to report.
        let tcc = preflight()
        guard isTCCCode || !tcc else {
            log("capture error \(ns.domain)(\(ns.code)) is NOT a permission problem: \(ns.localizedDescription)")
            return .underlying(ns.localizedDescription)
        }
        refusedInProcess = true
        let state = status()
        log("capture refused: \(ns.domain)(\(ns.code)) preflight=\(tcc) -> \(state.logToken)")
        return .permissionDenied(state)
    }

    // MARK: - Capture

    static func capture(maxWidth: CGFloat = 1280, quality: CGFloat = 0.7) async throws -> CapturedFrame {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw classify(error as NSError)
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
            // A denial can surface here rather than at SCShareableContent, so this
            // goes through the same classifier instead of being blanket-reported
            // as a generic capture failure.
            throw classify(error as NSError)
        }

        noteCaptureSucceeded()
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
