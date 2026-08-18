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
///     │ ○  │  — solid unread, hollow once opened, exactly as the grid draws
///     │ ◉  │
///     │    │
///     │ TB │  the wordmark, in the band the controls stand in
///     │ RA │  — always there, whatever the roster; hidden on hover
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
    private static let logoSlot: CGFloat = 40
    private static let lampSlot: CGFloat = 28
    /// The floor the hover controls land in: X and +, one `logoSlot` each.
    /// Reserved in the ARITHMETIC and not on screen — the wordmark draws over
    /// the same space at rest, because the mark and the controls never coexist.
    private static let controlsFloor: CGFloat = logoSlot * 2

    /// How many lamps the column shows, and the number the height is derived
    /// FROM rather than checked against.
    ///
    /// Ruled 16 Aug, from the screenshots: "the collapsed state shows 8, but
    /// the size has room for 10 at least." Both halves were true, which is the
    /// tell that the two constants had drifted apart — the cap was the grid's
    /// old eight-row floor written down a second time, the height was a round
    /// 380 chosen next to it, and nothing tied them together, so the column
    /// carried 36pt of dead band under the last lamp and cut the roster anyway.
    /// Robert's own panel had eleven active agents and the strip showed eight
    /// greens, dropping both working blues off the bottom of a column that
    /// looked half empty.
    ///
    /// So the cap is the ruling and the height is its consequence.
    ///
    /// RE-RULED 17 Aug, and the two rulings are one trade seen from both ends.
    /// Ten lamps bought the roster and spent the mark: with the wordmark moved
    /// into the controls' 80pt floor, eleven letters landed at 5pt and Robert
    /// could not read them — "too small not readable, maybe make bigger and go
    /// back to 8 lamps". Eight it is. The two slots that buys go to the mark,
    /// which is the thing you look at to know whose column this is.
    static let lampCapacity = 8

    /// The band the mark gets, and the reason the frame did not change.
    ///
    /// 136pt: two lamp slots handed back plus the controls' own 80. The X and
    /// the + still stand in the bottom 80 of it — they are 40pt targets and
    /// growing them was never the ask — so the mark simply has more room above
    /// them than they use, and still shares their floor rather than reserving
    /// its own.
    ///
    /// Sized from the TYPE, not chosen and then filled: eleven letters need
    /// `markTypeFloor` points of rhythm each to stay legible, and 136 is what
    /// that comes to with the inset. That is the arithmetic that failed last
    /// time, run in the right direction.
    private static let markFloor: CGFloat = 136

    /// Fixed, so the strip never resizes under the user — the logo slot, every
    /// lamp slot, and the band the mark and the controls share. DERIVED: see
    /// `lampCapacity`. Still 400: eight lamps and a readable mark cost exactly
    /// what ten lamps and an unreadable one did.
    static let height: CGFloat =
        logoSlot + CGFloat(lampCapacity) * lampSlot + markFloor
    /// The mark lives in the controls' slot, at every roster size.
    ///
    /// It used to take whatever space the lamps left and vanish past five of
    /// them — "if there's more than 5 working rows, there's probably not room
    /// for the Tranquility Base" — which made the identity a function of how
    /// busy the machine happened to be, and on a full column it was simply
    /// gone. Ruled 17 Aug: "i would like our vertical tranquility base strip to
    /// fit in here, so we can always display it, so i guess we make smaller so
    /// it occupies same height as the two buttons and disappears on hover."
    ///
    /// So the mark is sized to a fixed band rather than to the leftovers, and
    /// it is the same swap every other control on this column already is: one
    /// slot, two faces, nothing reflowing.
    ///
    /// The band is `markFloor`, not `controlsFloor`. Fitting it to the two
    /// button rows was the 17 Aug version and it shipped illegible — the mark
    /// is the one thing here that has a MINIMUM size, so it sets the band's
    /// height instead of accepting it.
    private var wordmarkRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.markFloor)
    }

    /// The smallest the mark may render, in points.
    ///
    /// A floor, and the drill enforces it, because "is this readable" is not a
    /// question a layout answers on its own — the 17 Aug version computed 5pt
    /// from the space it was given, drew it correctly, passed an ink count, and
    /// was unreadable on the actual screen. 8pt is where the mark sat for the
    /// whole life of the design before that pass, unremarked; below it the type
    /// stops being quiet and starts being absent.
    static let markTypeFloor: CGFloat = 8

    var onExpand: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onNewAgent: (() -> Void)?
    var onPick: ((String) -> Void)?

    /// Ready, working and fault only. Idle lamps do not appear collapsed —
    /// there is no reason to show a socket with nothing in it when the whole
    /// column exists to answer one question.
    private(set) var lamps: [StateLegend.SessionRow] = []
    private var hovering = false

    /// Which of the floor's two faces the last paint put there.
    ///
    /// Recorded BY `draw`, so it is a record of what happened rather than a
    /// second copy of the condition. A drill that re-asks "is it hovering?"
    /// proves only that the expression it just wrote agrees with itself.
    enum FloorFace: Equatable { case mark, controls }
    private(set) var lastFloorPaint: FloorFace?

    /// The point size the mark last actually rendered at — recorded by the
    /// draw, so the drill measures the type that was PAINTED rather than the
    /// constant somebody intended.
    private(set) var lastMarkTypeSize: CGFloat = 0

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

    /// The ink actually PAINTED at the centre of lamp `index`.
    ///
    /// Sampled off the rendered view rather than recomputed, because the bug
    /// this guards was a view that never asked the question at all: a drill
    /// that re-evaluates `read == .opened` would have passed on the strip that
    /// shipped, since the expression was right everywhere it existed and
    /// absent here. A solid lamp answers with its state colour; a hollow one
    /// has nothing in the middle, so the answer is transparent.
    func lampCentreInkForTesting(_ index: Int) -> NSColor? {
        guard index < lamps.count,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let slot = lampRect(index)
        // PIXELS, not points, and the bitmap counts rows from the top while the
        // view's geometry does not. The first version passed neither: it read
        // point coordinates straight into `colorAt`, which on a 2x display
        // samples a quarter of the way in from the corner — empty ground, so
        // every lamp came back transparent and "hollow" was true of all of
        // them. A drill that measures nothing reports the same as a drill that
        // measures the right thing and finds it correct.
        let sx = CGFloat(rep.pixelsWide) / bounds.width
        let sy = CGFloat(rep.pixelsHigh) / bounds.height
        return rep.colorAt(x: Int(slot.midX * sx),
                           y: Int((bounds.maxY - slot.midY) * sy))
    }

    /// Does a FULL column still leave the hover controls their floor?
    ///
    /// The property that ties `lampCapacity` to `height`. Raising the cap
    /// without moving the frame is the drift that put eight lamps in a column
    /// sized for ten and, run the other way, would push the last lamp through
    /// the X and the +.
    var lampsClearTheMarkForTesting: Bool {
        lampRect(Self.lampCapacity - 1).minY >= Self.markFloor - 0.5
    }

    /// The controls stand INSIDE the mark's band, so nothing is reserved twice
    /// — the property that lets both live at the bottom of a fixed frame.
    var controlsSitInsideTheMarkForTesting: Bool {
        wordmarkRect.contains(dismissRect.union(newAgentRect))
    }

    /// The type the mark actually rendered at, against the floor it owes.
    var markTypeIsLegibleForTesting: Bool {
        lastMarkTypeSize >= Self.markTypeFloor
    }

    /// A drill cannot move the mouse, and hover is the whole swap.
    func setHoveringForTesting(_ on: Bool) {
        hovering = on
        needsDisplay = true
        display()
    }

    /// Write the rendered column to a PNG, next to the log, on every deploy.
    ///
    /// Ruled 17 Aug, and it is a process fix rather than a feature: "really you
    /// should eval if it's visible before shipping". The 5pt mark passed a
    /// paint record, an ink count and a geometry check, and was illegible on
    /// the screen — the properties a drill can state are not the whole of what
    /// a panel has to be. So the drill leaves a picture, at the panel's real
    /// pixel scale, and looking at it is one Read away for whoever ships next.
    ///
    /// One file, overwritten each launch: this is the current column, not an
    /// archive. `logs/deploys.log` already says which build drew it.
    @discardableResult
    func writeShot() -> URL? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/VoiceDispatch/strip-shot.png")
        do { try png.write(to: url) } catch { return nil }
        return url
    }

    /// How many pixels of the bottom slot actually carry ink.
    ///
    /// Counted rather than sampled at a point: the mark is fifteen small
    /// glyphs spread over 80pt, so no single pixel is reliably on it, and the
    /// failure worth catching is the whole run coming out invisible — a size
    /// clamped to nothing, or an early return. Zero here means the panel is
    /// unnamed.
    func floorInkForTesting() -> Int {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return 0 }
        cacheDisplay(in: bounds, to: rep)
        let sx = CGFloat(rep.pixelsWide) / bounds.width
        let sy = CGFloat(rep.pixelsHigh) / bounds.height
        let top = max(0, Int((bounds.maxY - wordmarkRect.maxY) * sy))
        let bottom = min(rep.pixelsHigh, Int((bounds.maxY - wordmarkRect.minY) * sy))
        var ink = 0
        for y in top..<bottom {
            for x in 0..<Int(bounds.width * sx)
            where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                ink += 1
            }
        }
        return ink
    }

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
        lamps = rows.filter { $0.lamp != .running }
            .prefix(Self.lampCapacity).map { $0 }
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

    /// Rule 1 of the hover standard: every band of the strip does something —
    /// expand, dismiss, new agent, or pick a lamp — so the whole strip carries
    /// the cursor. It is the one surface where the hover swap already announced
    /// itself, and it still never said "clickable", only "there is more here".
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
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

        // The floor has two faces and never both. No roster condition any more:
        // the mark is sized to this slot, so a full column cannot crowd it out.
        if hovering {
            drawGlyph(StateLegend.Glyph.denied, in: dismissRect, color: StateLegend.Palette.faint)
            drawGlyph("+", in: newAgentRect, color: StateLegend.Palette.faint)
            lastFloorPaint = .controls
        } else {
            drawWordmark()
            lastFloorPaint = .mark
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

    /// The same lamp the grid draws, at another width — INCLUDING the read
    /// state, which this column simply did not carry.
    ///
    /// Solid unread, a ring once opened, in the state's own colour: the rule
    /// `GridRowView` has followed since 16 Aug, and one this view was never
    /// told about, so every lit lamp came out solid. Robert saw the two widths
    /// side by side and the disagreement was the whole report — "the collapse
    /// state shows only the filled dots, whereas the uncollapsed state shows
    /// both filled and unfilled". His grid had one solid green and eight
    /// hollow; his strip had nine identical solid greens, which says every
    /// agent is waiting on him when only one of them was.
    ///
    /// The hollow test is `GridRowView`'s verbatim, deliberately: it is the
    /// same question about the same row, and the two views disagreeing about
    /// it is precisely the defect. `asksForYou` keeps advisory blue solid —
    /// news has no read state — and 1.5pt keeps the ring from reading as a
    /// smudge at 9px, both for the reasons the grid states at its own call
    /// site.
    private func drawLamps() {
        for (i, row) in lamps.enumerated() {
            let slot = lampRect(i)
            let d = StateLegend.Lamp.diameter
            let dot = NSRect(x: slot.midX - d / 2, y: slot.midY - d / 2, width: d, height: d)
            if row.read == .opened && row.lamp.asksForYou {
                row.lamp.fill.setStroke()
                let path = NSBezierPath(ovalIn: dot.insetBy(dx: 0.75, dy: 0.75))
                path.lineWidth = 1.5
                path.stroke()
                continue
            }
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

        // Sized to a fixed BAND, and the band was sized to the type.
        //
        // The mark used to take whatever the lamps left, which made it a
        // different size on every roster and nothing at all past five of them.
        // The first fix put it in the controls' 80pt floor, which fixed the
        // disappearing and produced 5pt letters: "too small not readable".
        //
        // So the arithmetic now runs the other way. Eleven letters at
        // `markTypeFloor` set the band, the band set the frame, and the lamp
        // cap came down to eight to pay for it. `wordmarkRect` is 136pt and the
        // lamps are structurally forbidden from entering it (see
        // `lampsClearTheMarkForTesting`); the X and the + stand in its bottom
        // 80, so mark and controls still share one floor — mark at rest, glyphs
        // on hover.
        let inset: CGFloat = 6
        let baseY = wordmarkRect.minY + inset
        let available = wordmarkRect.height - inset * 2

        // Ambient, not ostentatious: the hint line's ink, a step below the
        // chrome the lamps and controls sit in. Legible when looked at, quiet
        // when not.
        let rhythm = available / CGFloat(left.count)
        // Clamped BELOW by the legibility floor rather than by whatever fits.
        // If a future edit shrinks the band, the mark holds its size and the
        // drill fails loudly — which is the opposite of what happened on 17
        // Aug, where the type quietly followed the space down to 5pt and every
        // property still passed.
        let size = max(Self.markTypeFloor, min(10, rhythm * 0.78))
        lastMarkTypeSize = size
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
