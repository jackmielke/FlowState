import Foundation
import Carbon.HIToolbox
import AppKit

/// Process-wide ⌘⇧2 via Carbon's RegisterEventHotKey (no Accessibility permission needed).
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    private let signature: OSType = 0x56425643 // 'VBVC'

    private init() {}

    /// ⌘⇧2
    func register(_ action: @escaping () -> Void) {
        guard ref == nil else { self.action = action; return }
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if hkID.id == 1 {
                DispatchQueue.main.async { GlobalHotkey.shared.action?() }
            }
            return noErr
        }, 1, &spec, nil, &handler)

        let hkID = EventHotKeyID(signature: signature, id: 1)
        let mods = UInt32(cmdKey | shiftKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_2), mods, hkID, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
