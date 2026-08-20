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
    /// Which display this frame actually came from. Not necessarily the one the user
    /// picked — a display can be unplugged between the pick and the capture — so the
    /// UI reports what was really sent rather than what was requested.
    let display: DisplayOption
}

/// One display the user can hand to the assistant.
///
/// `displayID` is the CoreGraphics id, which is what both ScreenCaptureKit and
/// `NSScreen` key off, and is stable for as long as the display stays attached. It is
/// NOT stable across unplug/replug or a reboot, which is why `AppState` re-resolves the
/// saved choice against the live list instead of trusting it.
struct DisplayOption: Identifiable, Hashable {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    /// The display holding the menu bar. Worth calling out: on a laptop plus monitor
    /// setup "which one is main" is the only thing that tells the two apart at a glance.
    let isMain: Bool
    /// `NSScreen.localizedName` when macOS knows one ("Built-in Retina Display",
    /// "LG UltraFine"), otherwise a positional fallback.
    let name: String

    var id: CGDirectDisplayID { displayID }

    var resolution: String { "\(width) × \(height)" }

    /// One line for a menu row: name plus the detail that disambiguates identical models.
    var menuLabel: String { isMain ? "\(name) (main)" : name }

    /// What the settings file stores for "whichever display the app is on right now".
    /// Safe as a sentinel because `kCGNullDirectDisplay` is 0 — no real display has it.
    static let followsActiveID: CGDirectDisplayID = 0
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

    // MARK: - Displays

    /// The display the app itself is on, i.e. what "follow the active display" resolves to.
    static func activeDisplayID() -> CGDirectDisplayID? {
        guard let main = NSScreen.main,
              let num = main.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return num.uint32Value
    }

    /// Human names, straight from AppKit. SCDisplay has no name of its own, so the two
    /// lists are joined on the CoreGraphics display id.
    private static func screenNames() -> [CGDirectDisplayID: String] {
        var out: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let name = screen.localizedName
            if !name.isEmpty { out[num.uint32Value] = name }
        }
        return out
    }

    /// Every display Vibe Voice is allowed to look at, in a stable order.
    ///
    /// Returns `[]` rather than throwing when permission is missing: the caller is a UI
    /// refresh that runs on launch and on every activation, and a blocked permission is
    /// already reported by its own card. The permission evidence is still updated on the
    /// way through, so a refusal here is not swallowed silently.
    static func displays() async -> [DisplayOption] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            noteCaptureSucceeded()
        } catch {
            _ = classify(error as NSError)
            return []
        }
        return describe(content.displays)
    }

    private static func describe(_ displays: [SCDisplay]) -> [DisplayOption] {
        let names = screenNames()
        let mainID = CGMainDisplayID()
        // Main display first, then a stable id order, so the list does not reshuffle
        // under the user's cursor between refreshes.
        let sorted = displays.sorted { a, b in
            if (a.displayID == mainID) != (b.displayID == mainID) { return a.displayID == mainID }
            return a.displayID < b.displayID
        }
        return sorted.enumerated().map { index, d in
            DisplayOption(
                displayID: d.displayID,
                width: d.width,
                height: d.height,
                isMain: d.displayID == mainID,
                name: names[d.displayID] ?? "Display \(index + 1)")
        }
    }

    // MARK: - Capture

    /// - Parameter displayID: the display to capture, or `nil` / an id that is no longer
    ///   attached to fall back to whichever display the app is on. Falling back beats
    ///   throwing: unplugging a monitor mid-session must not break the watch loop.
    static func capture(displayID: CGDirectDisplayID? = nil,
                        maxWidth: CGFloat = 1280,
                        quality: CGFloat = 0.7) async throws -> CapturedFrame {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw classify(error as NSError)
        }

        // Explicit pick first, then the display holding the key window, then the first
        // one attached.
        let picked = displayID.flatMap { id in content.displays.first { $0.displayID == id } }
        if let wanted = displayID, picked == nil {
            log("requested display \(wanted) is not attached — falling back to the active one")
        }

        let target: SCDisplay
        if let picked {
            target = picked
        } else if let active = activeDisplayID(),
                  let match = content.displays.first(where: { $0.displayID == active }) {
            target = match
        } else if let first = content.displays.first {
            target = first
        } else {
            throw ScreenCaptureError.noDisplay
        }

        // Described against the FULL list so the positional fallback name ("Display 2")
        // matches what the picker shows, rather than restarting at 1 for the one display
        // that happened to win.
        let described = describe(content.displays).first { $0.displayID == target.displayID }
            ?? DisplayOption(displayID: target.displayID, width: target.width, height: target.height,
                             isMain: target.displayID == CGMainDisplayID(), name: "Display")

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
        return CapturedFrame(dataURI: uri, thumbnail: thumb, bytes: jpeg.count, display: described)
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
