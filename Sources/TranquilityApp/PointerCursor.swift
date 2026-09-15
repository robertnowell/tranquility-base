import AppKit

/// The pointing hand, on a window that is never key.
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
/// A tracking area with `.cursorUpdate` and `.activeAlways` does not care
/// whether the window is key: AppKit calls `cursorUpdate(with:)` on entry,
/// and the view sets the hand. On exit it asks the view underneath, which
/// sets whatever it wants, or the arrow. One helper, so the eight controls
/// that each wrote their own `resetCursorRects` cannot each get it wrong
/// again.
enum PointerCursor {
    /// Install the tracking. Call from `updateTrackingAreas`, after removing
    /// the old areas; `rect` nil tracks the whole view (`.inVisibleRect`).
    static func track(_ view: NSView, rect: NSRect? = nil) {
        var options: NSTrackingArea.Options = [.cursorUpdate, .activeAlways]
        if rect == nil { options.insert(.inVisibleRect) }
        view.addTrackingArea(NSTrackingArea(rect: rect ?? .zero, options: options,
                                            owner: view, userInfo: nil))
    }

    /// What `cursorUpdate(with:)` does when the view is a control.
    static func show() { NSCursor.pointingHand.set() }
}
