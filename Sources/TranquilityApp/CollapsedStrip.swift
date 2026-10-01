import AppKit
import TranquilityCore

/// The grid, collapsed to a pill at the right edge: how many agents have
/// something you have not read, and nothing else.
///
/// Ruled 1 Oct 2026, from a mockup (option A): "change the collapsed view to
/// just show the number of unread green lamps ... basically a pill, fully
/// rounded, and also remove the create button from the collapsed view." It
/// replaces the column of up to ten lamps (ruled 08 to 18 Aug; its history
/// is in git log for this file): the column answered "who" and "in
/// what state", and the collapsed panel's one job turned out to be "is there
/// anything for me", which is a number.
///
/// It is still a second WIDTH, not a second face: `PanelState` gains no case,
/// and the idle face hands this view the same `SessionRow`s it hands the grid.
///
/// ## The layout, top to bottom
///
///     ╭────╮  a green lamp: solid when something is unread, a ring at zero
///     │ ●  │  (becomes Expand on hover)
///     │ 6  │  the count of unread green lamps, dimmed at zero
///     ╰────╯  (becomes Close on hover)
///
/// Two slots, two faces each, and the frame never changes: the 08 Aug rule
/// that nothing on this surface moves on hover survives the redesign. The
/// mockup drew the hover state taller; holding the height is what keeps the
/// panel from jumping under the pointer. The + is gone: new agents start
/// from the expanded panel and the status menu.
///
/// Working (blue) and fault (red) lamps do not appear here any more. The
/// expanded grid still shows every one of them.
final class CollapsedStrip: NSView {

    static let width: CGFloat = 40
    private static let slot: CGFloat = 38
    /// Fixed: the panel morphs to exactly this, and the corners round to half
    /// the width, which is what makes it a pill.
    static let height: CGFloat = slot * 2

    var onExpand: (() -> Void)?
    var onDismiss: (() -> Void)?

    /// Agents with a green lamp you have not opened: the grid's solid greens.
    private(set) var unreadCount = 0
    private var hovering = false

    /// Which face the last paint put on the pill. Recorded BY `draw`, so a
    /// drill reads what was painted rather than re-asking the condition.
    enum Face: Equatable { case count, controls }
    private(set) var lastFace: Face?

    // MARK: - The arrival glow

    /// The lamp is STATE; the glow is an EVENT, one breath and gone. Kept from
    /// the column, behind the lamp, which is now the pill's one fixed point.
    private var glowColor: NSColor?
    private var glowStrength: CGFloat = 0
    private var glowTimer: Timer?
    /// `var` so the drill can shorten it.
    static var glowSeconds: TimeInterval = 1.6
    var currentGlowStrength: CGFloat { glowColor == nil ? 0 : glowStrength }
    var glowTimerIsActive: Bool { glowTimer?.isValid == true }

    func flash(_ lamp: Lamp) {
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
        let p = elapsed / Self.glowSeconds
        glowStrength = p < 0.2 ? CGFloat(p / 0.2) : CGFloat(pow(1 - (p - 0.2) / 0.8, 1.7))
        needsDisplay = true
    }

    // MARK: - Rows

    /// The grid's own rule for a solid green: a ready lamp you have not opened.
    static func unread(in rows: [SessionRow]) -> Int {
        rows.filter { $0.lamp == .ready && $0.read != .opened }.count
    }

    func show(rows: [SessionRow]) {
        unreadCount = Self.unread(in: rows)
        needsDisplay = true
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        PointerCursor.track(self)
    }
    override func cursorUpdate(with event: NSEvent) { PointerCursor.show() }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    /// A drill cannot move the mouse, and hover is the whole swap.
    func setHoveringForTesting(_ on: Bool) {
        hovering = on
        needsDisplay = true
        display()
    }

    // MARK: - Hit targets

    private var topRect: NSRect {
        NSRect(x: 0, y: bounds.maxY - Self.slot, width: bounds.width, height: Self.slot)
    }
    private var bottomRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.slot)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Anywhere on the pill expands it, except Close while hovering.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if hovering, bottomRect.contains(p) { onDismiss?(); return }
        onExpand?()
    }

    // MARK: - Paint

    override func draw(_ dirtyRect: NSRect) {
        // No background: the pill IS the panel's glass, rounded to half its
        // width while collapsed (see `Geometry`). Painting here would square it.
        drawGlow()
        if hovering {
            drawGlyph(StateLegend.Glyph.back, in: topRect, color: StateLegend.Palette.secondary)
            drawGlyph(StateLegend.Glyph.denied, in: bottomRect, color: StateLegend.Palette.secondary)
            lastFace = .controls
        } else {
            drawLamp()
            drawCount()
            lastFace = .count
        }
    }

    private var lampDot: NSRect {
        let d: CGFloat = 12
        return NSRect(x: topRect.midX - d / 2, y: topRect.minY + 8, width: d, height: d)
    }

    /// Solid green when something is unread, a green ring at zero: the same
    /// read rule the grid draws, at the size of one lamp.
    private func drawLamp() {
        if unreadCount > 0 {
            Lamp.ready.fill.setFill()
            NSBezierPath(ovalIn: lampDot).fill()
        } else {
            Lamp.ready.fill.setStroke()
            let ring = NSBezierPath(ovalIn: lampDot.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    private func drawCount() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: unreadCount > 0 ? StateLegend.Palette.ink : StateLegend.Palette.hint,
        ]
        let text = (unreadCount > 99 ? "99+" : "\(unreadCount)") as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: bottomRect.midX - size.width / 2, y: bottomRect.maxY - size.height - 4),
                  withAttributes: attrs)
    }

    private func drawGlow() {
        guard let glowColor, glowStrength > 0.01 else { return }
        let centre = NSPoint(x: lampDot.midX, y: lampDot.midY)
        for step in stride(from: 3, through: 1, by: -1) {
            let radius = 9 + CGFloat(step) * 5
            let alpha = 0.16 * glowStrength / CGFloat(step)
            glowColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius,
                                        width: radius * 2, height: radius * 2)).fill()
        }
    }

    private func drawGlyph(_ glyph: String, in rect: NSRect, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: StateLegend.Face.chrome(13),
            .foregroundColor: color,
        ]
        let s = glyph as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
               withAttributes: attrs)
    }

    // MARK: - Evidence

    /// The ink painted at the lamp's centre: green when solid, nothing when it
    /// is a ring. Sampled off the render, in pixels, top-down.
    func lampCentreInkForTesting() -> NSColor? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let sx = CGFloat(rep.pixelsWide) / bounds.width
        let sy = CGFloat(rep.pixelsHigh) / bounds.height
        return rep.colorAt(x: Int(lampDot.midX * sx), y: Int((bounds.maxY - lampDot.midY) * sy))
    }

    /// Pixels of ink in the count's slot: zero means no number was drawn.
    func countInkForTesting() -> Int {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return 0 }
        cacheDisplay(in: bounds, to: rep)
        let sx = CGFloat(rep.pixelsWide) / bounds.width
        let sy = CGFloat(rep.pixelsHigh) / bounds.height
        let top = max(0, Int((bounds.maxY - bottomRect.maxY) * sy))
        let bottom = min(rep.pixelsHigh, Int((bounds.maxY - bottomRect.minY) * sy))
        var ink = 0
        for y in top..<bottom {
            for x in 0..<Int(bounds.width * sx) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                ink += 1
            }
        }
        return ink
    }

    /// A picture of the pill next to the log, every deploy: the panel's only
    /// visual evidence, and the answer to "did anybody look at it".
    @discardableResult
    func writeShot() -> URL? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = QueueStore.supportDirectory.appendingPathComponent("strip-shot.png")
        do { try png.write(to: url) } catch { return nil }
        return url
    }
}
