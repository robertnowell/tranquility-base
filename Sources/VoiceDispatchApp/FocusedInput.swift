import AppKit
import ApplicationServices

/// Wispr's rule: if a text input has focus, type there; otherwise clipboard.
///
/// This works at all only because the panel is a non-activating window — focus
/// never leaves the field you were working in when a gesture fires. Everything here
/// needs Accessibility trust: both reading the focused element and posting the ⌘V.
/// Untrusted → callers fall back to the clipboard, which is never wrong, just less.
enum FocusedInput {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Ask once, with the system prompt, so the capability is discoverable.
    static func requestTrustOnce() {
        // The framework global is not concurrency-safe under Swift 6; the key is a
        // stable public constant, so spell it.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// The app owning a focused, editable text element — nil when there is none.
    static func focusedEditableApp() -> String? {
        guard trusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        var element: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                            &element) == .success,
              let el = element else { return nil }
        let axEl = el as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(axEl, kAXRoleAttribute as CFString, &role)
        let editableRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(axEl, kAXSelectedTextAttribute as CFString, &settable)
        guard editableRoles.contains(role as? String ?? "") || settable.boolValue else {
            return nil
        }
        var pid: pid_t = 0
        AXUIElementGetPid(axEl, &pid)
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "the focused app"
    }

    /// Paste via the clipboard, then restore what was there. The clipboard route
    /// beats AX insertion for compatibility (Electron apps, web views); restoring
    /// after a beat keeps the user's copy buffer out of our blast radius.
    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)  // V
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        if let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }
}
