import AppKit

/// Every button on the panel answers the pointer the same way.
///
/// The standard (docs/rulings/ruling-the-panel-answers-the-pointer.md):
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
        didSet { guard hovering != oldValue else { return }; paintInk(); paintFace() }
    }

    /// The hover, without a mouse. `mouseEntered` takes an NSEvent no drill can
    /// post, and the panel's only coverage is drills.
    func setHovered(_ hovered: Bool) { hovering = hovered }

    /// A control with TWO FACES: the mark it wears at rest, and the mark it
    /// wears once the pointer is anywhere on the panel.
    ///
    /// Ruled 02 Sep, for the collapse control: at rest it is the site mark, so
    /// the grid always carries the app's own mark rather than a naked chevron
    /// pointing at nothing; the moment the pointer is on the panel it becomes
    /// the chevron, which is the control it has always been. The collapsed
    /// strip has done exactly this since 18 Aug (`CollapsedStrip.drawHeader`) —
    /// "the logo at rest, the Expand chevron while hovering, one slot two
    /// faces" — and the expanded face simply did not answer it.
    ///
    /// The pair is set together or not at all; a button with one image and no
    /// second face never enters this path, so nothing else on the panel changes.
    var restingFace: NSImage? { didSet { paintFace() } }
    var hoverFace: NSImage? { didSet { paintFace() } }

    /// Whether the pointer is on the SURFACE this control belongs to, as
    /// opposed to on the control itself.
    ///
    /// Deliberately not `hovering`: the ink step means "the pointer is on THIS
    /// one" (rule 2) and a panel-wide hover has no business brightening every
    /// control on it. Surface hover swaps the face and touches no colour.
    var surfaceHovered = false {
        didSet { guard surfaceHovered != oldValue else { return }; paintFace() }
    }

    private func paintFace() {
        guard let restingFace, let hoverFace else { return }
        let wanted = (surfaceHovered || hovering) ? hoverFace : restingFace
        guard image !== wanted else { return }
        image = wanted
    }

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
    /// Nothing here shrinks the target. These are the numbers a call site
    /// subtracts so the MARK lands on `StatusHUD.contentColumn` and the target
    /// overhangs outward, into the panel's own margin, where nothing else is
    /// competing for the space.
    ///
    /// Pinned once a two-faced control has been laid out. The faces are
    /// generated to share an ink edge, but they are rasterised separately, and
    /// a control whose alignment constant moved by a rounding step the moment
    /// the pointer arrived would MOVE under the pointer — the one thing rule 3
    /// forbids outright. So layout reads the face the panel was measured to,
    /// and the drill compares the other face against it rather than against a
    /// number that quietly followed it.
    var inkOverhang: (leading: CGFloat, trailing: CGFloat) {
        pinnedOverhang ?? Self.inkOverhang(of: image, target: pointerTarget)
    }

    private var pinnedOverhang: (leading: CGFloat, trailing: CGFloat)?

    /// Freeze the overhang at whatever mark is in the button right now. Called
    /// before a second face is hung on it, never after.
    func pinInkOverhang() {
        pinnedOverhang = Self.inkOverhang(of: image, target: pointerTarget)
    }

    /// How tall the MARK is, as opposed to the image around it.
    ///
    /// The number a second face is built to, so a control that swaps its mark
    /// swaps optical weight for optical weight: the site mark is generated at
    /// the chevron's own ink height rather than at a guessed point size, and
    /// the two faces cannot drift when either symbol is retuned.
    var inkHeight: CGFloat { Self.inkBox(of: image)?.height ?? 0 }

    /// Where an image's ink sits inside a `target`-wide slot, per side.
    ///
    /// Two boxes deep, and the second one is why the first attempt at aligning
    /// this still missed. A symbol button centres its image in the 26pt target,
    /// and the image is itself padded around the glyph — so aligning by
    /// `image.size` put the chevron's paint at 16.5 when the column is at 14
    /// (measured). This reads the columns that actually carry alpha.
    static func inkOverhang(of image: NSImage?,
                            target: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        guard let image, image.size.width > 0 else { return (0, 0) }
        let slack = (target - image.size.width) / 2
        guard let ink = inkBox(of: image) else { return (slack, slack) }
        return (slack + ink.minX, slack + (image.size.width - ink.maxX))
    }

    /// The alpha bounds of an image, in its own points — rasterised on demand.
    static func inkBox(of image: NSImage?) -> NSRect? {
        guard let image, image.size.width > 0 else { return nil }
        let width = Int(image.size.width.rounded(.up))
        let height = max(1, Int(image.size.height.rounded(.up)))
        guard width > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSGraphicsContext.restoreGraphicsState()

        var minX = width, maxX = -1, minY = height, maxY = -1
        for x in 0..<width {
            for y in 0..<height where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return NSRect(x: CGFloat(minX), y: CGFloat(minY),
                      width: CGFloat(maxX - minX + 1),
                      height: CGFloat(maxY - minY + 1))
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

extension ConsoleButton {
    /// The panel's one door: a bordered-less inline button that reinks itself
    /// and wears a trailing chevron.
    ///
    /// Lifted out of OnboardingWindow when the setup checklist moved into its
    /// own view (29 Aug) and both the onboarding window and the settings tab
    /// needed to build the same control. Copying it would have been three lines
    /// and the beginning of two doors that drift.
    static func door(_ title: String, ink: NSColor,
                     target: AnyObject?, action: Selector) -> ConsoleButton {
        let button = ConsoleButton(title: title, target: target, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        let font = ChromeType.mono(ofSize: 11, weight: .medium)
        button.font = font
        button.reink = { [weak button] color in
            button?.attributedTitle = ChromeType.line(
                title + " \u{203A}", font: font, color: color)
        }
        button.restingInk = ink
        return button
    }
}
