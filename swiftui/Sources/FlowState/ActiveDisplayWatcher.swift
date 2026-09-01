import Foundation
import AppKit
import FlowStateCore

/// Watches which screen is being worked on and says when it changes.
///
/// Polled rather than event-driven. A global mouse monitor is the obvious alternative and
/// it is worse here: it fires thousands of times during any normal movement to answer a
/// question that changes at most a few times a minute, and `NSEvent.mouseLocation` costs
/// nothing to read. Twice a second is well inside the settle window, so the gate sees
/// enough samples to do its job.
///
/// The rule for what counts as a change lives in `ActiveDisplayGate` — see there for why
/// it is not simply "wherever the pointer is".
@MainActor
final class ActiveDisplayWatcher {

    /// Called with the new display id, on the main actor, only when it actually changes.
    var onChange: ((CGDirectDisplayID) -> Void)?

    private var gate = ActiveDisplayGate()
    private var timer: Timer?

    /// Every quarter of a second — two samples inside the shortest settle window, so a
    /// deliberate move is caught within about half a second of arriving.
    private static let interval: TimeInterval = 0.25

    var current: CGDirectDisplayID? { gate.active }

    func start() {
        guard timer == nil else { return }
        gate.adopt(ScreenCapture.activeDisplayID())
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common` so it keeps running while a menu is open or a window is being
        // dragged — which is exactly when somebody is moving between screens.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-reads without waiting, for the moment a display is plugged in or removed and
    /// the previous answer may no longer refer to anything.
    func resync() {
        gate.adopt(ScreenCapture.activeDisplayID())
    }

    private func tick() {
        guard let changed = gate.observe(ScreenCapture.pointerDisplayID(), at: Date()) else { return }
        onChange?(changed)
    }
}
