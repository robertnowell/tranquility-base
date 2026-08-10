import AppKit
import TranquilityCore

/// The grid, collapsed to a single column of lamps at the right edge.
///
/// Ruled 08–10 Aug (docs/ruling-the-collapsed-strip.md). One sentence: **the grid
/// has two widths, the user owns which one, and the app never changes it.**
///
/// It is a second WIDTH, not a second face. `PanelState` does not gain a case and
/// `render()` does not gain an arm — the idle face decides which of two views is
/// on screen and hands both the same `SessionRow` data. A session that implements
/// this as a new state has misread it.
///
/// ## The layout, top to bottom
///
///     ┌────┐  logo mark          — becomes Expand on hover
///     │ ◉  │  lamps, ready/working/fault only, idle omitted
///     │ ◉  │
///     │ ◉  │
///     │    │
///     │ TB │  the wordmark, in whatever space the lamps leave
///     │ RA │  — hidden on hover, and hidden past 5 lamps
///     │ AS │
///     │ NE │
///     └────┘  X and + appear here on hover, in the wordmark's slot
///
/// ## Why nothing moves
///
/// The height is FIXED and the lamps are top-aligned, so a session lighting up
/// never shifts the ones above it and never resizes the panel. Every control is
/// a swap into a slot that already exists — the logo's slot becomes Expand, the
/// wordmark's slot becomes X and +. A dedicated row for any of them would push
/// the lamps down, and lamps holding still is the entire property that makes a
/// 40px column readable at a glance. Any change that reflows this column on
/// hover has lost the point of the design.
@MainActor
final class CollapsedStrip: NSView {

    static let width: CGFloat = 40
    /// Fixed, so the strip never resizes under the user. Sized for the grid's
    /// 8-row cap: the logo slot, eight lamp slots, and the remainder — which at
    /// five lamps is the lower half and at eight is too little for the wordmark,
    /// which is exactly the ruled cutoff.
    static let height: CGFloat = 380
    private static let logoSlot: CGFloat = 40
    private static let lampSlot: CGFloat = 28
    /// Past this many lamps the wordmark is hidden: "if there's more than 5
    /// working rows, there's probably not room for the Tranquility Base."
    private static let wordmarkLampLimit = 5

    var onExpand: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onNewAgent: (() -> Void)?
    var onPick: ((String) -> Void)?

    /// Ready, working and fault only. Idle lamps do not appear collapsed —
    /// there is no reason to show a socket with nothing in it when the whole
    /// column exists to answer one question.
    private(set) var lamps: [StateLegend.SessionRow] = []
    private var hovering = false

    func show(rows: [StateLegend.SessionRow]) {
        lamps = rows.filter { $0.lamp != .running }.prefix(8).map { $0 }
        needsDisplay = true
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    // MARK: - Hit targets
    //
    // Drawn rather than built from NSButtons: three controls sharing two slots
    // with a wordmark, all of which appear and vanish on hover, is more state
    // than a view hierarchy wants to hold. One `draw` and one `mouseDown` keeps
    // the swap honest — what is painted IS what is clickable, by construction.

    private var logoRect: NSRect {
        NSRect(x: 0, y: bounds.maxY - Self.logoSlot, width: bounds.width, height: Self.logoSlot)
    }

    private func lampRect(_ index: Int) -> NSRect {
        NSRect(x: 0,
               y: bounds.maxY - Self.logoSlot - CGFloat(index + 1) * Self.lampSlot,
               width: bounds.width, height: Self.lampSlot)
    }

    private var dismissRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.logoSlot)
    }

    private var newAgentRect: NSRect {
        NSRect(x: 0, y: Self.logoSlot, width: bounds.width, height: Self.logoSlot)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if logoRect.contains(p) { onExpand?(); return }
        if hovering, dismissRect.contains(p) { onDismiss?(); return }
        if hovering, newAgentRect.contains(p) { onNewAgent?(); return }
        for (i, row) in lamps.enumerated() where lampRect(i).contains(p) {
            onPick?(row.id)
            return
        }
    }

    // MARK: - Paint

    override func draw(_ dirtyRect: NSRect) {
        StateLegend.Palette.surface.setFill()
        bounds.fill()

        // The left edge is the only border: the strip is flush to the screen's
        // right edge, so the other three have nothing to separate it from.
        StateLegend.Palette.hairline.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()

        drawHeader()
        drawLamps()

        if hovering {
            drawGlyph(StateLegend.Glyph.denied, in: dismissRect, color: StateLegend.Palette.faint)
            drawGlyph("+", in: newAgentRect, color: StateLegend.Palette.faint)
        } else if lamps.count <= Self.wordmarkLampLimit {
            drawWordmark()
        }
    }

    /// The logo at rest, the Expand chevron while hovering. One slot, two faces.
    private func drawHeader() {
        if hovering {
            drawGlyph(StateLegend.Glyph.back, in: logoRect, color: StateLegend.Palette.secondary)
        } else {
            // The mark: a filled ring, the same circle vocabulary as the lamps
            // one size up. Not a glyph — the panel owns no typeface small
            // enough to read as a mark at this size.
            let d: CGFloat = 13
            let r = NSRect(x: logoRect.midX - d / 2, y: logoRect.midY - d / 2, width: d, height: d)
            StateLegend.Palette.secondary.setStroke()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            ring.stroke()
            StateLegend.Palette.secondary.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 4.5, dy: 4.5)).fill()
        }
    }

    private func drawLamps() {
        for (i, row) in lamps.enumerated() {
            let slot = lampRect(i)
            let d = StateLegend.Lamp.diameter
            let dot = NSRect(x: slot.midX - d / 2, y: slot.midY - d / 2, width: d, height: d)
            row.lamp.fill.setFill()
            NSBezierPath(ovalIn: dot).fill()
            if let ring = row.lamp.ring {
                ring.setStroke()
                let path = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    /// TRANQUILITY down the left, BASE down the right, both reading top to
    /// bottom with every glyph upright.
    ///
    /// Upright and stacked, NOT rotated: a rotated run reads as a book spine,
    /// which is a "look at me" the panel is built to avoid. Per-glyph placement
    /// rather than an `NSTextField` with newlines, because the stack needs
    /// optical centring per letter — `I` and `T` want different side bearings
    /// than `Q` and `B`, and a text field would rag them against a shared box.
    private func drawWordmark() {
        let top = bounds.maxY - Self.logoSlot - CGFloat(lamps.count) * Self.lampSlot
        // Leave the bottom slot clear so the wordmark never sits where X will
        // appear — the swap should look like a swap, not a reflow.
        let region = NSRect(x: 0, y: Self.logoSlot,
                            width: bounds.width, height: max(0, top - Self.logoSlot))
        let left = Array("TRANQUILITY")
        guard region.height >= CGFloat(left.count) * 9 else { return }

        let rhythm = min(14, region.height / CGFloat(left.count))
        let size = min(9, rhythm * 0.72)
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: StateLegend.Palette.faint,
        ]
        // Two columns inside 40px: the left one carries the long word, the
        // right one BASE, offset down a letter so the pair reads as a mark
        // rather than as two lists that happen to be adjacent.
        let leftX = bounds.width * 0.30
        let rightX = bounds.width * 0.68
        let start = region.maxY - rhythm

        for (i, ch) in left.enumerated() {
            let s = String(ch) as NSString
            let w = s.size(withAttributes: attrs).width
            s.draw(at: NSPoint(x: leftX - w / 2, y: start - CGFloat(i) * rhythm), withAttributes: attrs)
        }
        for (i, ch) in Array("BASE").enumerated() {
            let s = String(ch) as NSString
            let w = s.size(withAttributes: attrs).width
            s.draw(at: NSPoint(x: rightX - w / 2,
                               y: start - CGFloat(i + 1) * rhythm), withAttributes: attrs)
        }
    }

    private func drawGlyph(_ glyph: String, in rect: NSRect, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: color,
        ]
        let s = glyph as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
               withAttributes: attrs)
    }
}
