import Foundation
import Carbon.HIToolbox
import AppKit

/// A key combination Flow listens for everywhere, not just when it is in front.
///
/// Carbon's `RegisterEventHotKey` is used rather than an event tap because it needs no
/// Accessibility permission — which matters here, since this app has already spent
/// enough of the user's patience on macOS privacy dialogs.
struct HotkeyCombo: Equatable, Identifiable {
    let id: String
    let label: String
    let keyCode: UInt32
    let modifiers: UInt32

    static let cmdShiftSpace = HotkeyCombo(
        id: "cmdShiftSpace", label: "⌘⇧Space",
        keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey))

    static let optionSpace = HotkeyCombo(
        id: "optionSpace", label: "⌥Space",
        keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))

    static let cmdShiftF = HotkeyCombo(
        id: "cmdShiftF", label: "⌘⇧F",
        keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | shiftKey))

    static let ctrlShiftSpace = HotkeyCombo(
        id: "ctrlShiftSpace", label: "⌃⇧Space",
        keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey))

    static let ctrlShiftF = HotkeyCombo(
        id: "ctrlShiftF", label: "⌃⇧F",
        keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(controlKey | shiftKey))

    static let cmdShiftL = HotkeyCombo(
        id: "cmdShiftL", label: "⌘⇧L",
        keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | shiftKey))

    /// Split rather than one list of six: a segmented control with seven segments in a
    /// 440-point pane is unreadable, and the two keys should not offer each other's
    /// combos anyway — binding both to the same chord registers one and silently loses
    /// the other.
    static let cmdShiftR = HotkeyCombo(
        id: "cmdShiftR", label: "⌘⇧R",
        keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | shiftKey))

    static let ctrlShiftR = HotkeyCombo(
        id: "ctrlShiftR", label: "⌃⇧R",
        keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | shiftKey))

    static let optionShiftR = HotkeyCombo(
        id: "optionShiftR", label: "⌥⇧R",
        keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | shiftKey))

    static let ctrlShiftEscape = HotkeyCombo(
        id: "ctrlShiftEscape", label: "⌃⇧Esc",
        keyCode: UInt32(kVK_Escape), modifiers: UInt32(controlKey | shiftKey))

    static let cmdShiftEscape = HotkeyCombo(
        id: "cmdShiftEscape", label: "⌘⇧Esc",
        keyCode: UInt32(kVK_Escape), modifiers: UInt32(cmdKey | shiftKey))

    static let cmdShiftPeriod = HotkeyCombo(
        id: "cmdShiftPeriod", label: "⌘⇧.",
        keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(cmdKey | shiftKey))

    /// The wake key. ⌃Q by default.
    ///
    /// A bare Control chord rather than one of the ⌘⇧ pairs because this is the key
    /// somebody hits without looking, mid-sentence, while their other hand is on a
    /// mouse — and Control is the modifier the left little finger already rests near.
    ///
    /// One thing it takes with it: ⌃Q is XON in a terminal, the key that resumes output
    /// after ⌃S paused it. A Carbon hotkey is registered ahead of every app, so binding
    /// this steals ⌃Q from Terminal, iTerm, tmux and anything else doing flow control.
    /// Very few people use ⌃S/⌃Q deliberately, but the ones who do will notice — hence
    /// the two alternates beside it.
    static let ctrlQ = HotkeyCombo(
        id: "ctrlQ", label: "⌃Q",
        keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey))

    static let ctrlShiftQ = HotkeyCombo(
        id: "ctrlShiftQ", label: "⌃⇧Q",
        keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey | shiftKey))

    static let ctrlOptionSpace = HotkeyCombo(
        id: "ctrlOptionSpace", label: "⌃⌥Space",
        keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))

    static let summonChoices = [cmdShiftSpace, optionSpace, cmdShiftF]
    static let hushChoices = [ctrlShiftEscape, cmdShiftEscape, cmdShiftPeriod]
    static let recordChoices = [cmdShiftR, ctrlShiftR, optionShiftR]
    static let connectChoices = [ctrlShiftF, ctrlShiftSpace, cmdShiftL]
    static let wakeChoices = [ctrlQ, ctrlShiftQ, ctrlOptionSpace]

    static let all = summonChoices + connectChoices + recordChoices + hushChoices + wakeChoices

    static func named(_ id: String) -> HotkeyCombo {
        all.first { $0.id == id } ?? .cmdShiftSpace
    }
}

/// Process-wide hotkeys. Several can be registered; each gets its own slot.
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    private struct Slot {
        var ref: EventHotKeyRef?
        var action: () -> Void
        /// Set only for slots that care about the key coming up again.
        ///
        /// Almost nothing does — a shortcut fires when you press it, and the release is
        /// noise. Hold-to-dictate is the exception: the whole gesture is defined by how
        /// long the key stays down, which cannot be known from key-down alone.
        var release: (() -> Void)?
    }

    private var slots: [UInt32: Slot] = [:]
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x56425643 // 'VBVC'

    private init() {}

    /// ⌘⇧2 — show the model your screen. Kept as its own entry point since it is wired
    /// from several places.
    func register(_ action: @escaping () -> Void) {
        bind(id: 1, keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey), action: action)
    }

    /// The summon key. Rebinding replaces whatever was there, so switching combos in
    /// Settings does not leave the old one live.
    func registerSummon(_ combo: HotkeyCombo, action: @escaping () -> Void) {
        bind(id: 2, keyCode: combo.keyCode, modifiers: combo.modifiers, action: action)
    }

    func unregisterSummon() { unbind(id: 2) }

    /// Connect / hang up, from anywhere.
    ///
    /// A separate slot from summon on purpose: bringing the window forward and opening a
    /// session are different intentions, and the one worth having under a finger is the
    /// one that does not require finding the window first.
    func registerConnect(_ combo: HotkeyCombo, action: @escaping () -> Void) {
        bind(id: 3, keyCode: combo.keyCode, modifiers: combo.modifiers, action: action)
    }

    func unregisterConnect() { unbind(id: 3) }

    /// Start or stop recording from anywhere.
    ///
    /// The one a screen recorder cannot do without: what you want to record is, by
    /// definition, not this app's window, so reaching for it means leaving the thing you
    /// were about to capture.
    func registerRecord(_ combo: HotkeyCombo, action: @escaping () -> Void) {
        bind(id: 4, keyCode: combo.keyCode, modifiers: combo.modifiers, action: action)
    }

    func unregisterRecord() { unbind(id: 4) }

    /// Stop. Never starts anything.
    ///
    /// Separate from the connect key on purpose: that one toggles, and a toggle is the
    /// wrong shape for a panic key. Somebody reaching for silence in a hurry does not
    /// know what state the app is in, and a key that might CONNECT is worse than no key.
    func registerHush(_ combo: HotkeyCombo, action: @escaping () -> Void) {
        bind(id: 5, keyCode: combo.keyCode, modifiers: combo.modifiers, action: action)
    }

    func unregisterHush() { unbind(id: 5) }

    /// Turn it on. Never turns it off.
    ///
    /// The mirror image of the hush key, and a different slot from connect for the same
    /// reason hush is: connect TOGGLES, and a toggle cannot answer "just be on". Someone
    /// hitting this has already decided what they want, and half the time they do not
    /// know whether a session is open — so a key that might hang up is the wrong key.
    func registerWake(_ combo: HotkeyCombo, action: @escaping () -> Void) {
        bind(id: 6, keyCode: combo.keyCode, modifiers: combo.modifiers, action: action)
    }

    func unregisterWake() { unbind(id: 6) }

    /// The dictation key, which reports both halves of the press.
    ///
    /// Its own slot rather than an option on the wake key because the two answer different
    /// questions, and because this is the only slot in the app that needs key-up at all.
    /// The gesture — hold to dictate, double press to open a session, tap to hang one up —
    /// is decided by `HotkeyGesture.Recognizer`; this just reports the raw edges.
    func registerDictation(_ combo: HotkeyCombo,
                           down: @escaping () -> Void,
                           up: @escaping () -> Void) {
        bind(id: 7, keyCode: combo.keyCode, modifiers: combo.modifiers, action: down, release: up)
    }

    func unregisterDictation() { unbind(id: 7) }


    // MARK: -

    private func bind(id: UInt32,
                      keyCode: UInt32,
                      modifiers: UInt32,
                      action: @escaping () -> Void,
                      release: (() -> Void)? = nil) {
        installHandlerIfNeeded()
        unbind(id: id)

        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        // A combo another app already owns fails here rather than silently doing nothing,
        // which is worth knowing about when a key "doesn't work".
        guard status == noErr else {
            FileHandle.standardError.write(Data(
                "[hotkey] could not register id \(id) (OSStatus \(status)) — another app may own it\n".utf8))
            return
        }
        slots[id] = Slot(ref: ref, action: action, release: release)
    }

    private func unbind(id: UInt32) {
        if let slot = slots[id], let ref = slot.ref { UnregisterEventHotKey(ref) }
        slots[id] = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        // Two specs now, not one. Registering only kEventHotKeyPressed is why hold-to-
        // dictate could not work at all: Carbon delivers the release as a separate event
        // kind, and a handler that never asked for it simply never hears the key come up.
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let id = hkID.id
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            DispatchQueue.main.async { GlobalHotkey.shared.fire(id, released: released) }
            return noErr
        }, specs.count, &specs, nil, &handler)
    }

    /// Slots without a `release` closure ignore key-up entirely, so adding the second
    /// event spec above cannot make any existing shortcut fire twice.
    fileprivate func fire(_ id: UInt32, released: Bool = false) {
        guard let slot = slots[id] else { return }
        if released {
            slot.release?()
        } else {
            slot.action()
        }
    }

    func unregister() {
        for id in slots.keys { unbind(id: id) }
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

/// Bringing Flow forward from anywhere.
enum Summon {
    /// Raises the window and focuses the app. If it is already front and focused, this
    /// hides it instead — so the same key both summons and dismisses, which is what
    /// people expect of a launcher-style shortcut.
    @MainActor
    static func toggle() {
        let app = NSApplication.shared
        if app.isActive, app.keyWindow != nil {
            app.hide(nil)
            return
        }
        app.activate(ignoringOtherApps: true)
        for w in app.windows where w.canBecomeMain {
            w.makeKeyAndOrderFront(nil)
            break
        }
    }

    /// Raises and focuses, and never hides.
    ///
    /// `toggle()` is wrong for anything that means "be here": pressing the wake key
    /// while the window happens to be in front would send it away, which is the exact
    /// opposite of what was asked for. Deliberately unconditional — being told to come
    /// forward when you are already forward is a no-op, not a reason to leave.
    @MainActor
    static func bringToFront() {
        let app = NSApplication.shared
        // Closing the last window leaves the app running (see `AppDelegate`) but with
        // nothing to raise, so a window is asked for rather than assumed. Going through
        // SwiftUI's own `openWindow` — captured by `WindowReopener` while the scene was
        // alive — because a `Window(id:)` scene cannot be rebuilt from the AppKit side.
        if app.windows.first(where: { $0.canBecomeMain }) == nil {
            AppState.current?.reopenMainWindow?()
        }
        app.activate(ignoringOtherApps: true)
        for w in app.windows where w.canBecomeMain {
            // Minimised counts as "running in the background", and ordering a window in
            // the Dock to the front does nothing at all — it has to come out first.
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
            break
        }
    }
}
