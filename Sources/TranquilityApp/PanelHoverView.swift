import AppKit

/// Is the pointer anywhere on the panel?
///
/// A transparent sheet over the whole surface rather than a tracking area on
/// the background view, which is what this wants to be and cannot: the
/// background carries the entire panel underneath it — rows, buttons, the drop
/// overlay — and a superview's tracking area is not a dependable answer to "is
/// the pointer over any of us" once the children are tracking their own. This
/// view has no children at all, so its enter and exit are the panel's edges and
/// nothing else.
///
/// It refuses hit-testing, so it never takes a click, a cursor rect or a drag
/// off the controls it covers. Tracking areas are dispatched by geometry, not
/// by `hitTest`, which is what makes an invisible, untouchable sheet work.
///
/// Cheap by construction: two events per visit to the panel, no polling and no
/// per-frame scan — the hover scan that ran every frame was one of the three
/// main-thread stalls that earned CLAUDE.md rule 9.
final class PanelHoverView: NSView {
    var onHover: ((Bool) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .activeAlways: the panel is a .nonactivatingPanel and never becomes
        // key, so .activeInKeyWindow would simply never fire.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    /// Answer the question from the pointer's ACTUAL position, once.
    ///
    /// A panel that is ordered out while the pointer is on it gets no exit
    /// event, and comes back believing it is still hovered. Rather than poll
    /// for that, the faces that care ask at the moment they arm: one point
    /// lookup on a face change, which is not a hot path.
    func resync() {
        guard let window, !isHiddenOrHasHiddenAncestor else { onHover?(false); return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        onHover?(window.isVisible && bounds.contains(point))
    }
}
