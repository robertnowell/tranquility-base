import AppKit

/// The pointing hand, on a window that is never key, in an app that is
/// never active.
///
/// Rule 1 of the hover standard (docs/rulings/ruling-the-panel-answers-the-
/// pointer.md) says the cursor is what tells a control from a label on this
/// panel. Every control implemented it with `addCursorRect`, and none of it
/// ever worked: AppKit honours cursor rects only in the KEY window, and the
/// panel is `.nonactivatingPanel`, key only while a text field is taking
/// input. Reported 15 Sep 2026 from a Prod card: "adding a cursor on the
/// speaking, settings, go to agent and open report. I think those do warrant
/// a cursor." They always did; the rule was written, and the pixels never
/// kept it, on any face, for anyone.
///
/// The hand is set on enter and the arrow on exit, by a watcher that owns
/// the tracking area, so the control has nothing to override. `set`, not
/// `push`/`pop`: a face can change under a hovered control and the exit
/// never arrive, and a pushed hand with no pop is a hand that sticks.
///
/// Not measured by a machine: a synthetic pointer (CGEvent moves) drives
/// enter and exit but never the window server's cursor tracking, so every
/// probe read the arrow, including over a key window with a cursor rect
/// that visibly shows the hand to a real mouse. This wants a hand on it.
enum PointerCursor {
    /// One per tracked view; the tracking area's owner, retained by the
    /// view through its userInfo so it lives as long as the area does.
    @MainActor final class Watcher: NSResponder {
        private let enabled: () -> Bool
        private var pushed = false
        init(enabled: @escaping () -> Bool) { self.enabled = enabled; super.init() }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

        override func mouseEntered(with event: NSEvent) {
            guard enabled() else { return }
            NSCursor.pointingHand.set()
            pushed = true
        }
        override func mouseExited(with event: NSEvent) {
            guard pushed else { return }
            NSCursor.arrow.set()
            pushed = false
        }
        override func cursorUpdate(with event: NSEvent) {
            if enabled() { NSCursor.pointingHand.set() }
        }
    }

    /// Install the tracking. Call from `updateTrackingAreas`, after removing
    /// the old areas. `rect` nil tracks the whole view (`.inVisibleRect`).
    /// `when` gates it, for a label that is a door only sometimes.
    @MainActor static func track(_ view: NSView, rect: NSRect? = nil,
                      when enabled: @escaping () -> Bool = { true }) {
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .cursorUpdate, .activeAlways]
        if rect == nil { options.insert(.inVisibleRect) }
        let watcher = Watcher(enabled: enabled)
        view.addTrackingArea(NSTrackingArea(rect: rect ?? .zero, options: options,
                                            owner: watcher, userInfo: ["watcher": watcher]))
    }

    /// What a control's own `cursorUpdate(with:)` may still call.
    static func show() { NSCursor.pointingHand.set() }
}
