import AppKit

/// Every button on the panel answers the pointer the same way.
///
/// The standard (docs/ruling-the-panel-answers-the-pointer.md):
///
///  1. the CURSOR says a thing is a control — a pointing hand over its hit
///     rect, everywhere, because on this panel a control and a label are the
///     same object to the eye by design (the card's actions are quiet text with
///     no lozenge, ruled) and nothing else distinguishes them at rest;
///  2. the INK confirms the pointer is on THIS one — one step up the control's
///     own colour, `StateLegend.hovered` — a fixed +8 ΔL*;
///  3. nothing moves, nothing grows, no lozenge appears, no hue changes. A
///     panel where things jump under the pointer is an interface asking to be
///     looked at, which is the product this one exists not to be;
///  4. no control rests at `ink`. The brightest ink is the prose's; a control
///     resting there is louder than the message and has no step left to take.
///
/// A row-shaped control keeps the wash it already had (`Palette.hover`) instead
/// of the ink step — see `GridRowView`. Rule 1 applies to it all the same.
final class ConsoleButton: NSButton {
    /// The ink at rest. Its hover value is decided by the ramp, not here, so
    /// "one step" cannot become a different distance on a different button.
    ///
    /// Nil for a button that paints its own title for reasons the ramp does not
    /// know about — the settings tabs, whose ink carries WHICH TAB IS OPEN, a
    /// louder signal than the pointer and not one hover may overwrite. Rule 1
    /// still applies to those: they get the cursor, and their confirmation is
    /// the selection they already draw.
    var restingInk: NSColor? { didSet { paintInk() } }

    /// A door's title, held as plain words so the hover step can rebuild it in
    /// the new ink — rendered through `StateLegend.BottomLine.door`, the bottom
    /// line's one lexicon, so a hovering door cannot drift from a resting one.
    /// Buttons carrying a symbol leave this nil and are re-inked through
    /// `contentTintColor`.
    var wordmark: String? { didSet { paintInk() } }

    /// For a button drawn some third way — the chip's ✕ is a monospaced glyph
    /// in an attributed title, which neither a tint nor a wordmark reaches.
    /// Set this BEFORE `restingInk`, which is what triggers the first paint.
    var reink: ((NSColor) -> Void)?
    private var hovering = false {
        didSet { guard hovering != oldValue else { return }; paintInk() }
    }

    /// The hover, without a mouse. `mouseEntered` takes an NSEvent no drill can
    /// post, and the panel's only coverage is drills.
    func setHovered(_ hovered: Bool) { hovering = hovered }

    /// A hidden button gets no hover events, so a button hidden while the
    /// pointer is on it would come back lit. Faces swap buttons constantly.
    override var isHidden: Bool {
        didSet { if isHidden { hovering = false } }
    }

    private func paintInk() {
        guard let restingInk else { return }
        let color = hovering ? StateLegend.hovered(restingInk) : restingInk
        if let reink {
            reink(color)
        } else if let wordmark {
            attributedTitle = StateLegend.BottomLine.door(wordmark, color: color)
        } else {
            contentTintColor = color
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// The pointer target this control keeps, whatever size its mark is.
    /// Ruled at 26 — "a hit target well under the ~24pt a fingertip-sized
    /// control needs even for a mouse".
    var pointerTarget: CGFloat = 26

    /// How far this control's box reaches past the MARK inside it, per side.
    ///
    /// Two boxes deep, and the second one is why the first attempt at this
    /// still missed. A symbol button centres its image in the 26pt target, and
    /// the image is itself padded around the glyph — so aligning by
    /// `image.size` put the chevron's paint at 16.5 when the column is at 14
    /// (measured). This rasterises the image once, at build, and finds the
    /// columns that actually carry alpha.
    ///
    /// Nothing here shrinks the target. These are the numbers a call site
    /// subtracts so the MARK lands on `StatusHUD.contentColumn` and the target
    /// overhangs outward, into the panel's own margin, where nothing else is
    /// competing for the space.
    var inkOverhang: (leading: CGFloat, trailing: CGFloat) {
        guard let image, image.size.width > 0 else { return (0, 0) }
        let slack = (pointerTarget - image.size.width) / 2
        let width = Int(image.size.width.rounded(.up))
        let height = max(1, Int(image.size.height.rounded(.up)))
        guard width > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return (slack, slack) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSGraphicsContext.restoreGraphicsState()

        var first = width, last = -1
        for x in 0..<width {
            for y in 0..<height where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                first = min(first, x); last = max(last, x)
                break
            }
        }
        guard last >= first else { return (slack, slack) }
        return (slack + CGFloat(first),
                slack + (image.size.width - CGFloat(last + 1)))
    }

    /// The hover ink, for the drill. Reading it off the button rather than
    /// recomputing it is the difference between asserting the standard and
    /// asserting the arithmetic twice.
    var hoverInkForTesting: NSColor? { restingInk.map(StateLegend.hovered) }

    func setHoveringForTesting(_ on: Bool) { hovering = on }
    var currentInkForTesting: NSColor? {
        // Whatever PAINTS, not whatever a particular path happens to use. This
        // asked `wordmark != nil` and so read `contentTintColor` for a button
        // that repaints through `reink` — which is how `backWearsIt` went red
        // the moment the back button's ‹ started being composed as an
        // attributed title. Same mistake as the face census made an hour
        // earlier, in the same file: the instrument looked beside the pixels.
        if attributedTitle.length > 0 {
            return attributedTitle.attribute(.foregroundColor, at: 0,
                                             effectiveRange: nil) as? NSColor
        }
        return contentTintColor
    }
}
