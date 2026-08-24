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

    static let summonChoices = [cmdShiftSpace, optionSpace, cmdShiftF]
    static let hushChoices = [ctrlShiftEscape, cmdShiftEscape, cmdShiftPeriod]
    static let recordChoices = [cmdShiftR, ctrlShiftR, optionShiftR]
    static let connectChoices = [ctrlShiftF, ctrlShiftSpace, cmdShiftL]

    static let all = summonChoices + connectChoices + recordChoices + hushChoices

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

    // MARK: -

    private func bind(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
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
        slots[id] = Slot(ref: ref, action: action)
    }

    private func unbind(id: UInt32) {
        if let slot = slots[id], let ref = slot.ref { UnregisterEventHotKey(ref) }
        slots[id] = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let id = hkID.id
            DispatchQueue.main.async { GlobalHotkey.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    fileprivate func fire(_ id: UInt32) { slots[id]?.action() }

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
}
