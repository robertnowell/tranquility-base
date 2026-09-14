import AppKit
import TranquilityCore

/// A label that is also a door: the breadcrumb pill on a card, and the grid
/// footer's signature.
///
/// A click target with no affordance is a secret, and a card that grows a button
/// for something the eye is already resting on is the detail this pass exists to
/// remove. The cursor is the whole affordance: nothing changes until the pointer
/// arrives, and then it says "this opens".
///
/// `isADoor` is false whenever there is nowhere to go — the pill on a face with
/// no way home rides this same label, and a word that offers to open nothing is
/// worse than a word that offers nothing.
///
/// The card's TITLE used to be one of these (06 Aug to 14 Sep). It is a plain
/// label now: GO TO AGENT is the door, and the name only says whose card it is.
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

/// The card's prose: words to read, and nothing else.
///
/// Not selectable, not a responder, not even a hit target (ruled 14 Sep). From
/// 16 Aug to 14 Sep this was a selectable field with a gate on WHO could start
/// a selection, because a line quoted out of a card by hand seemed worth the
/// machinery. Robert, on a launch card: "the name and the spoken text, that's
/// not actionable, so it doesn't need a cursor. You shouldn't even really be
/// able to highlight it." So the I-beam goes, the highlight goes, and with them
/// the field editor that once selected a whole card on its own (the 16 Aug
/// screenshot this class was written for) — a fault that cannot recur in a
/// field that has no editor to install.
///
/// `hitTest` yields to the surface, so a press on the words is a press on the
/// card: that is what arms card paste, and it used to need its own hook here
/// because the selection swallowed the event first.
final class CardBodyLabel: NSTextField {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
