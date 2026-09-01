import AppKit
import ApplicationServices
import FlowStateCore

/// Putting dictated text where the cursor already is, in somebody else's app.
///
/// This is the half of dictation that has no good API. macOS offers two ways and both are
/// compromises:
///
///  - **The accessibility API.** Ask the focused element for its value and set a new one.
///    Clean, no clipboard involvement, no synthetic keys — and it silently fails in a
///    large fraction of real apps. Electron apps, terminals, most web text areas and
///    anything drawing its own text view either refuse `kAXValueAttribute` writes or
///    accept them and then re-render the old value.
///  - **Paste.** Put the text on the pasteboard and synthesise ⌘V. Works essentially
///    everywhere, because pasting is a thing every text surface already handles. The cost
///    is that it stomps on the clipboard, which is a real intrusion — people keep things
///    there.
///
/// So: try accessibility first because it is clean, fall back to paste because it works,
/// and always put the clipboard back. Wispr Flow makes the same trade; you can watch it
/// happen if you have a clipboard manager running, which is exactly the tell.
enum TextInserter {

    enum Method: String {
        case accessibility
        case paste
    }

    enum Failure: Error, LocalizedError {
        case notTrusted
        case noFocusedElement
        case bothMethodsFailed

        var errorDescription: String? {
            switch self {
            case .notTrusted:
                return "FlowState needs Accessibility permission to type into other apps."
            case .noFocusedElement:
                return "Nothing has a text cursor right now."
            case .bothMethodsFailed:
                return "Could not insert the text into that app."
            }
        }
    }

    /// Whether macOS will let us do any of this. The Dictate tab reports the same value.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Insert `text` at the caret of whatever is frontmost.
    ///
    /// Returns which method worked, for the log — when a user says "it typed nothing in
    /// app X", the first thing worth knowing is whether we tried to paste or to set a
    /// value, because those fail for entirely different reasons.
    @discardableResult
    @MainActor
    static func insert(_ text: String) throws -> Method {
        guard !text.isEmpty else { return .accessibility }
        guard isTrusted else { throw Failure.notTrusted }

        if insertViaAccessibility(text) { return .accessibility }
        if insertViaPaste(text) { return .paste }
        throw Failure.bothMethodsFailed
    }

    // MARK: - Accessibility

    /// Append to the focused element's value via AX.
    ///
    /// Deliberately conservative: if anything is unexpected — no focused element, no
    /// readable value, a selection rather than a caret — this returns false and lets the
    /// paste path have it, rather than guessing and destroying text the user typed.
    @MainActor
    private static func insertViaAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return false }
        // swiftlint:disable:next force_cast
        let target = element as! AXUIElement

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, kAXValueAttribute as CFString, &valueRef) == .success,
              let existing = valueRef as? String else { return false }

        // Where the caret is. Without this we would have to append to the end, which is
        // wrong the moment somebody dictates into the middle of a sentence.
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef else { return false }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return false }

        let ns = existing as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return false }
        let updated = ns.replacingCharacters(in: NSRange(location: range.location, length: range.length),
                                             with: text)

        guard AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString,
                                           updated as CFTypeRef) == .success else { return false }

        // Put the caret after what we inserted. A failure here is cosmetic — the text
        // landed — so it does not fall through to the paste path, which would double it.
        var caret = CFRange(location: range.location + text.utf16.count, length: 0)
        if let newRange = AXValueCreate(.cfRange, &caret) {
            AXUIElementSetAttributeValue(target, kAXSelectedTextRangeAttribute as CFString, newRange)
        }
        return true
    }

    // MARK: - Paste

    /// Pasteboard + synthetic ⌘V, then put the clipboard back.
    ///
    /// The restore is on a delay and that delay is not arbitrary. The paste is
    /// asynchronous from our point of view: we post the keystroke and the frontmost app
    /// reads the pasteboard whenever it gets round to it. Restoring immediately is a race
    /// that pastes the user's *old* clipboard contents instead of their words — rare
    /// enough to survive testing and infuriating in daily use.
    @MainActor
    private static func insertViaPaste(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }

        pb.clearContents()
        pb.setString(text, forType: .string)

        guard postCommandV() else { return false }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            pb.clearContents()
            guard let saved, !saved.isEmpty else { return }
            let items: [NSPasteboardItem] = saved.map { dict in
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                return item
            }
            pb.writeObjects(items)
        }
        return true
    }

    /// Synthesise ⌘V into whatever is frontmost.
    private static func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let v: CGKeyCode = 0x09 // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // Annotated so our own ⌘V cannot be read back as a user keystroke by anything
        // listening — including this app's own hotkey layer.
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}
