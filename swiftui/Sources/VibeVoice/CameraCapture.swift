import Foundation
import AVFoundation
import AppKit
import os
import VibeVoiceCore

/// What macOS will let this process do with the camera.
///
/// Deliberately the same shape as `ScreenPermission`, minus the `needsRestart` case: the
/// camera grant, unlike screen recording, is picked up by a running process the moment it
/// is granted, so there is nothing to relaunch for.
enum CameraPermission: Equatable {
    case granted
    /// Refused, or refused-and-remembered. Either way the fix is System Settings.
    case denied
    /// Never asked. The system prompt has not been shown yet.
    case notAsked
    /// Screen Time or an MDM profile has turned the camera off entirely. Nothing the
    /// user can do inside the privacy pane will change it, so saying "turn it on in
    /// System Settings" would be a wild goose chase.
    case restricted

    var canCapture: Bool { self == .granted }

    var title: String {
        switch self {
        case .granted:    return "Camera is on"
        case .denied:     return "Camera is off"
        case .notAsked:   return "Camera has not been asked for yet"
        case .restricted: return "Camera is blocked on this Mac"
        }
    }

    var bannerText: String {
        switch self {
        case .granted:    return "Camera is on for \(kSystemAppName)."
        case .denied:     return "Camera is off for \(kSystemAppName) — turn it on in \(CapturePermission.camera.settingsPath)."
        case .notAsked:   return "\(kSystemAppName) will ask for the camera the first time you record with it."
        case .restricted: return "The camera is blocked on this Mac by Screen Time or a device profile."
        }
    }
}

/// The cameras this Mac has, and whether we are allowed to use one.
///
/// Kept apart from `VideoTrackWriter` because two very different things want to know
/// about cameras: the writer, which needs one device and needs it now, and Settings,
/// which needs the list and the permission state and must not start a capture to get it.
enum CameraCapture {

    private static let log = Logger(subsystem: "com.jackmielke.vibevoice", category: "camera")

    /// One camera, as the picker shows it.
    ///
    /// `id` is `AVCaptureDevice.uniqueID`, which — unlike a CoreGraphics display id —
    /// *is* stable across unplug and reboot, so it is safe to persist. It is still
    /// re-resolved against the live list before use, because the camera it names may
    /// simply not be plugged in today.
    struct Option: Identifiable, Hashable {
        let id: String
        let name: String
        let width: Int
        let height: Int
        /// True for the one macOS would pick on its own — the built-in FaceTime camera on
        /// a laptop, whatever is first otherwise.
        let isDefault: Bool

        var menuLabel: String { isDefault ? "\(name) (default)" : name }
        var resolution: String { width > 0 ? "\(width) × \(height)" : "" }
    }

    /// Everything that can act as a face camera.
    ///
    /// `.external` and `.continuityCamera` are in the list on purpose: an iPhone on a
    /// stand is the best camera most people own, and a Mac mini has no built-in one at
    /// all, so a discovery session limited to `.builtInWideAngleCamera` would show an
    /// empty picker on a machine with two working cameras attached.
    static func devices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .external, .continuityCamera,
        ]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                mediaType: .video,
                                                position: .unspecified).devices
    }

    static func options() -> [Option] {
        let preferred = AVCaptureDevice.default(for: .video)?.uniqueID
        return devices().map { device in
            let size = nativeSize(of: device)
            return Option(id: device.uniqueID,
                          name: device.localizedName,
                          width: size.width,
                          height: size.height,
                          isDefault: device.uniqueID == preferred)
        }
    }

    /// The saved choice if it is still attached, otherwise whatever macOS would pick.
    ///
    /// Falling back rather than failing: a camera that was unplugged since the setting
    /// was written should not turn the record button into an error message.
    static func device(id: String?) -> AVCaptureDevice? {
        if let id, !id.isEmpty, let match = devices().first(where: { $0.uniqueID == id }) {
            return match
        }
        if let id, !id.isEmpty {
            log.notice("saved camera \(id, privacy: .public) is not attached — using the default")
        }
        return AVCaptureDevice.default(for: .video) ?? devices().first
    }

    /// What the device is actually producing, before any scaling.
    static func nativeSize(of device: AVCaptureDevice) -> (width: Int, height: Int) {
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return (Int(dims.width), Int(dims.height))
    }

    /// The size to ask AVFoundation for.
    ///
    /// Camera-only: the plan's own dimensions, which were derived from this camera in the
    /// first place, so nothing is scaled twice.
    ///
    /// Composited: a little over twice the width the inset will be drawn at. Asking for
    /// the native 4K of a Continuity Camera and then shrinking it to a fifth of the frame
    /// on every single frame is the most expensive way to draw a small picture; asking for
    /// exactly the inset size instead leaves nothing in hand and looks soft the moment the
    /// inset fraction changes.
    static func outputSize(for plan: CapturePlan, device: AVCaptureDevice) -> (width: Int, height: Int) {
        let native = nativeSize(of: device)
        let longEdge = plan.mode == .full
            ? min(plan.profile.cameraLongEdge,
                  max(320, Int(Double(plan.width) * Double(VideoTrackWriter.insetWidthFraction) * 2)))
            : plan.profile.cameraLongEdge
        return CapturePlan.fit(width: native.width, height: native.height, longEdge: longEdge)
    }

    /// Opens the pane with the row the user is actually hunting for. The camera and
    /// screen-recording panes are different anchors in the same Privacy list, and sending
    /// someone to the wrong one is worse than sending them nowhere.
    static func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Permission

    static func permission() -> CameraPermission {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:    return .granted
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .notAsked
        @unknown default:    return .denied
        }
    }

    /// Asks, once, and reports what the answer turned out to be.
    ///
    /// `requestAccess` returning false is not the same as the user saying no — a second
    /// call after a denial returns false without prompting — so the answer is re-read
    /// from `authorizationStatus` rather than inferred from the return value.
    @discardableResult
    static func ensureAccess() async -> CameraPermission {
        let current = permission()
        guard current == .notAsked else { return current }
        log.notice("requesting camera access")
        _ = await AVCaptureDevice.requestAccess(for: .video)
        let now = permission()
        log.notice("camera access is now \(String(describing: now), privacy: .public)")
        return now
    }
}
