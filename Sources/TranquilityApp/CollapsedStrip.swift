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

    /// The arrival glow: a colour and how much of it is left, 1 → 0.
    ///
    /// The lamps are STATE — what is true right now, readable at any moment. The
    /// glow is an EVENT — this just happened. A user glancing over five minutes
    /// later should learn the state and nothing about the timing, which is what
    /// a transient carries and a lamp structurally cannot. It matters more since
    /// the spoken callsign died: without it, a collapsed strip says nothing at
    /// all when an agent returns except a lamp quietly changing colour.
    private var glowColor: NSColor?
    private var glowStrength: CGFloat = 0
    private var glowTimer: Timer?

    /// One breath, and it must not be a light show.
    ///
    /// `Lamp.working`'s own doc comment is the law here: "solid, never blinking —
    /// a room full of blinking lamps is the opposite of calm." So: a single
    /// rise-and-fall, slow enough to read as light rather than as a flash, and
    /// then gone completely. No loop, no residue, nothing to acknowledge. A glow
    /// that persists until dismissed is a notification badge, which is the thing
    /// this product exists to not be.
    /// `var` so the drill can shorten it. The decay is the property worth
    /// asserting; waiting 1.6 real seconds to assert it is not, and the first
    /// version's sleep pushed every later drill past the deploy gate's window —
    /// a test that makes the build look broken is worse than the bug it guards.
    static var glowSeconds: TimeInterval = 1.6

    /// What the drill reads to prove the glow decays rather than lingering.
    var currentGlowStrength: CGFloat { glowColor == nil ? 0 : glowStrength }

    func flash(_ lamp: StateLegend.Lamp) {
        glowTimer?.invalidate()
        glowColor = lamp.fill
        glowStrength = 1
        let started = Date()
        // Timer target/action rather than a closure: the closure form hands the
        // Timer itself across an isolation boundary, which Swift 6 refuses.
        let timer = Timer(timeInterval: 1.0 / 30, target: self,
                          selector: #selector(stepGlow), userInfo: started, repeats: true)
        glowTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

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
        // NO background fill and no border. The strip lives inside the panel's
        // own rounded, shadowed background — painting an opaque rectangle over
        // it squares off the corners, which is what the first version did.
        // Collapsing morphs the panel; it does not draw a new one.
        drawGlow()
        drawHeader()
        drawLamps()

        if hovering {
            drawGlyph(StateLegend.Glyph.denied, in: dismissRect, color: StateLegend.Palette.faint)
            drawGlyph("+", in: newAgentRect, color: StateLegend.Palette.faint)
        } else if lamps.count <= Self.wordmarkLampLimit {
            drawWordmark()
        }
    }

    @objc private func stepGlow(_ timer: Timer) {
        guard let started = timer.userInfo as? Date else { timer.invalidate(); return }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed < Self.glowSeconds else {
            glowStrength = 0
            glowColor = nil
            timer.invalidate()
            glowTimer = nil
            needsDisplay = true
            return
        }
        // Ease in over the first fifth, out over the rest. The slow tail is what
        // makes it read as calm: an even fade reads as a blink, a fast one as an
        // alert.
        let p = elapsed / Self.glowSeconds
        glowStrength = p < 0.2 ? CGFloat(p / 0.2) : CGFloat(pow(1 - (p - 0.2) / 0.8, 1.7))
        needsDisplay = true
    }

    /// A soft halo behind the logo mark, in the returning session's colour.
    ///
    /// Behind the LOGO rather than the lamp that changed: the logo is the strip's
    /// one fixed point, so the event always appears in the same place whatever
    /// the roster is doing. Lighting the lamp itself would move the announcement
    /// around the column and make the eye hunt for it, which is the opposite of
    /// glanceable.
    private func drawGlow() {
        guard let glowColor, glowStrength > 0.01 else { return }
        let centre = NSPoint(x: logoRect.midX, y: logoRect.midY)
        // Three rings, each fainter and wider — a gradient by hand, because a
        // real one would need a layer and this is drawn thirty times a second
        // for a second and a half, twice an hour.
        for step in stride(from: 3, through: 1, by: -1) {
            let radius = 9 + CGFloat(step) * 5
            let alpha = 0.16 * glowStrength / CGFloat(step)
            glowColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius,
                                        width: radius * 2, height: radius * 2)).fill()
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
        let left = Array("TRANQUILITY")
        let right = Array("BASE")

        // Anchored to the BOTTOM of the column, not hung under the lamps.
        //
        // The first version started the run immediately below the last lamp, so
        // on a three-lamp day the mark floated in the middle of the strip with
        // dead space under it — which is what it looked like, and it looked
        // like nothing on purpose. The mass belongs in the corner.
        //
        // Twelve points off the floor and no more. The first version reserved a
        // whole `logoSlot` beneath it for the X — 52pt of nothing under the
        // mark, which is not "at the bottom", it is hovering above it.
        //
        // Nothing needs reserving: the wordmark and the hover controls never
        // coexist. The mark is drawn only when NOT hovering, and X and + are
        // drawn only when hovering, so they can occupy the same floor.
        let baseY: CGFloat = 12
        let ceiling = bounds.maxY - Self.logoSlot - CGFloat(lamps.count) * Self.lampSlot - 6
        let available = ceiling - baseY
        guard available >= CGFloat(left.count) * 8 else { return }

        // Ambient, not ostentatious: the hint line's ink, a step below the
        // chrome the lamps and controls sit in. Legible when looked at, quiet
        // when not.
        let rhythm = min(13, available / CGFloat(left.count))
        let size = max(7, min(8.5, rhythm * 0.68))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: StateLegend.Palette.faint,
        ]

        // Both columns END on the same baseline — the pair is related to each
        // other rather than each centred in the column, which is what made the
        // first version read as two ragged lists instead of one mark.
        let leftX = bounds.width * 0.31
        let rightX = bounds.width * 0.69

        func stack(_ letters: [Character], centredOn x: CGFloat) {
            for (i, ch) in letters.enumerated() {
                let fromBottom = CGFloat(letters.count - 1 - i)
                let str = String(ch) as NSString
                let w = str.size(withAttributes: attrs).width
                str.draw(at: NSPoint(x: x - w / 2, y: baseY + fromBottom * rhythm),
                         withAttributes: attrs)
            }
        }
        stack(left, centredOn: leftX)
        stack(right, centredOn: rightX)
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
