import AppKit
import TranquilityCore

/// The card's identity label, when the identity is also a way back to the tab.
///
/// A click target with no affordance is a secret, and a card that grows a button
/// for something the eye is already resting on is the detail this pass exists to
/// remove. The cursor is the whole affordance: nothing changes until the pointer
/// arrives, and then it says "this opens".
///
/// `isADoor` is false whenever there is no live target — the app's own name on
/// the empty room rides this same label, and a name that offers to open nothing
/// is worse than a name that offers nothing.
final class DoorLabel: NSTextField {
    var isADoor = false {
        didSet {
            guard isADoor != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            if !isADoor { unlift() }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isADoor else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - Hover
    //
    // The pill was a door with a cursor and no answer: "Speaking is clickable,
    // but doesn't have any hover effect." The cursor is a promise the pixels
    // were not keeping, and it is the same promise `Controls` keeps by
    // brightening — so the pill brightens too, by the same rule and the same
    // step. Repainted rather than tinted: the placard is an attributed string
    // whose runs carry their own colours (the mark and the word, amber or
    // chrome), and `contentTintColor` does not reach them.

    private var resting: NSAttributedString?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    /// The hover, without a mouse — `mouseEntered` reads an NSEvent no drill
    /// can post, and a hover nobody can assert is a hover that silently stops
    /// working.
    func setHovered(_ hovered: Bool) {
        guard hovered else { return unlift() }
        guard isADoor, resting == nil else { return }
        let current = attributedStringValue
        resting = current
        attributedStringValue = StateLegend.hoveredInk(current)
    }

    private func unlift() {
        guard let resting else { return }
        attributedStringValue = resting
        self.resting = nil
    }

    /// The gesture recogniser does the work; this only keeps a dead label from
    /// swallowing clicks meant for the card behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isADoor ? super.hitTest(point) : nil
    }
}

/// The card's prose: selectable by hand, and by hand ONLY.
///
/// A selectable `NSTextField` is a valid key view, and a text field that becomes
/// first responder selects ALL of its text. The two faces that take the keyboard
/// — the list and the settings pane — hand it to whatever AppKit picks, which
/// was this label; from then on the field editor stayed installed and every
/// programmatic `stringValue` arrived pre-selected, so a card would come back
/// from a turn with its whole body highlighted and nobody had touched it
/// (screenshot, 16 Aug). The highlight was also unreadable, which is the panel's
/// appearance and is fixed where the panel is built.
///
/// Selecting prose off a card is worth keeping — it is how a line gets quoted
/// into a reply — so this does not switch selection off. It narrows WHO may
/// start one to a pointer press that lands on these words. Keyboard traversal,
/// the window's automatic first-responder pick, and a click anywhere else on
/// the panel are all refused, so a selection means a hand made it.
final class CardBodyLabel: NSTextField {
    /// The gate, taking its event as an argument so a drill can ask the
    /// question without a mouse: `acceptsFirstResponder` reads
    /// `NSApp.currentEvent`, which no test can set.
    func acceptsPress(_ event: NSEvent?) -> Bool {
        guard let event, let window, event.window === window else { return false }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .leftMouseDragged: break
        default: return false
        }
        return bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override var acceptsFirstResponder: Bool { acceptsPress(NSApp.currentEvent) }

    /// New words, no selection.
    ///
    /// Guarded on the WORDS rather than on the assignment: `paintInk` rewrites
    /// this label once per spoken word to advance the karaoke ink, and dropping
    /// a hand-made selection on a repaint that changed only colour would be the
    /// same bug pointing the other way.
    override var stringValue: String {
        get { super.stringValue }
        set {
            let changed = newValue != super.stringValue
            super.stringValue = newValue
            if changed { dropSelection() }
        }
    }

    override var attributedStringValue: NSAttributedString {
        get { super.attributedStringValue }
        set {
            let changed = newValue.string != super.attributedStringValue.string
            super.attributedStringValue = newValue
            if changed { dropSelection() }
        }
    }

    /// True while a hand-made selection is on screen. The drill's evidence, and
    /// read from the field editor rather than from a flag we set, because the
    /// defect is precisely the editor disagreeing with what we think we did.
    var hasSelection: Bool {
        guard let editor = currentEditor() else { return false }
        return editor.selectedRange.length > 0
    }

    func dropSelection() {
        guard currentEditor() != nil else { return }
        window?.makeFirstResponder(nil)
    }
}
