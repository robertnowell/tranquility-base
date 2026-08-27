import AppKit

/// The site mark: a lamp resting on a hairline.
///
/// Ruled 18 Aug from the identity research (docs/ — the brief lives in HQ under
/// 2026-08-18-tranquility-base-mark-system). It is drawn from the instrument
/// rather than applied to it: the circle is the 9px lamp that is this app's
/// entire status vocabulary, and the bar is the hairline that rules every strip
/// and footer. Nothing here is a new shape.
///
/// It answers to three readings at once, which is why it was chosen over a
/// fused TB lettermark and over a bare ring:
///
///   - a landing site — a body resting on a surface, which is the name;
///   - a figure — head above shoulders, the pictogram grammar of a person
///     standing attentively, so the mark reads as an agent waiting on you;
///   - the lamp itself — the same circle the panel lights, so the mark and the
///     status vocabulary are the same object at two sizes.
///
/// **Filled means the same thing here as everywhere else on the panel.** Solid
/// is unread/working — something wants you; hollow is heard, nothing new. That
/// rule is `GridRowView`'s and `CollapsedStrip`'s already, and the menu bar now
/// speaks it too rather than swapping to an unrelated symbol.
///
/// ## Why filled paths and not strokes
///
/// The ring is an ANNULUS — an outer oval with an inner oval punched out under
/// the even-odd rule — not a stroked circle. Apple's custom-symbol guidance is
/// explicit (WWDC21): "make sure to convert any strokes to paths", "avoid using
/// open paths", flat fills only. A stroked path also scales its own line width
/// with the transform in ways that are easy to get wrong at 16px; a filled
/// annulus is the same shape at every size by construction.
enum SiteMark {

    /// The design grid. Every number below is in these units, and the mark is
    /// drawn into a 16×16 box because that is the menu bar's real working size
    /// — 16×16pt inside a 22pt bar is the practitioner figure for a circular
    /// item to carry the same optical weight as Apple's own items.
    static let grid: CGFloat = 16

    // Geometry, stated once. The clearances are the ones small-icon systems
    // hold to: ≥1 unit between separate shapes (Octicons' rule at 16px), and a
    // ring wall of 1.6 units, which sits in the 1–1.5px band every major system
    // lands on at this size with a little extra for the dark ground.
    private static let ringCentreY: CGFloat = 9.8
    private static let ringOuter: CGFloat = 4.9
    private static let ringWall: CGFloat = 1.6
    private static let barY: CGFloat = 1.6
    private static let barHeight: CGFloat = 1.6
    private static let barInset: CGFloat = 1.5

    /// The mark as one path, in a 16×16 box with y up (AppKit's own direction).
    ///
    /// One path for both shapes so the whole mark fills in a single pass — a
    /// template image is an alpha mask, and two fills with two winding rules is
    /// how you get a seam nobody sees until it is on a light menu bar.
    /// `wall` and `bar` are overridable so a small rendering can THICKEN them.
    /// Below about 32px the design-grid proportions put the ring wall under a
    /// device pixel and the mark greys out — the failure Fluent states plainly:
    /// "as product icons scale below 48 pixels, they simplify in detail in
    /// favor of readability". Simplification here means fewer, fatter shapes,
    /// never a different mark.
    static func path(filled: Bool,
                     wall: CGFloat = ringWall,
                     bar: CGFloat = barHeight) -> NSBezierPath {
        let p = NSBezierPath()
        let outer = NSRect(x: 8 - ringOuter, y: ringCentreY - ringOuter,
                           width: ringOuter * 2, height: ringOuter * 2)
        p.appendOval(in: outer)
        if !filled {
            p.appendOval(in: outer.insetBy(dx: wall, dy: wall))
        }
        p.appendRect(NSRect(x: barInset, y: barY,
                            width: grid - barInset * 2, height: bar))
        p.windingRule = .evenOdd
        return p
    }

    /// A template image at `size` points square.
    ///
    /// `isTemplate` is the whole contract on the menu bar: macOS discards the
    /// colour and uses the alpha, tinting for light bars, dark bars and the
    /// selected state. It is also why this mark can never carry a lamp colour
    /// up there — ruled already, in
    /// docs/rulings/ruling-an-arrival-does-not-move-the-panel.md.
    static func templateImage(size: CGFloat = 16, filled: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size),
                            flipped: false) { _ in
            let scale = size / grid
            let transform = NSAffineTransform()
            transform.scale(by: scale)
            transform.concat()
            NSColor.black.setFill()
            path(filled: filled).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Draw the mark centred in `rect`, scaled to `height` points tall.
    ///
    /// Sized and centred on the mark's own INK, not on its 16-unit box: the
    /// drawing occupies about 13.1 of those units vertically and sits low in
    /// them, so fitting the box would both undersize the mark and hang it below
    /// the middle of whatever slot it is in.
    static func draw(in rect: NSRect, height: CGFloat,
                     filled: Bool = false, color: NSColor) {
        let mark = path(filled: filled)
        let ink = mark.bounds
        let scale = height / ink.height
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX - ink.midX * scale,
                             yBy: rect.midY - ink.midY * scale)
        transform.scale(by: scale)
        transform.concat()
        color.setFill()
        mark.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The app icon's artwork at any pixel size: the console ground, rounded on
    /// Apple's grid, with the mark on it.
    ///
    /// The 824-in-1024 content box and its 185.4 corner radius are the numbers
    /// from Apple's own icon templates. They are not published as prose
    /// anywhere — an Apple Developer Forums thread complains about exactly that
    /// — so they are recorded here as measured convention rather than spec.
    /// `VOICE_DISPATCH_TEST_ICON`, set only by `scripts/bundle.sh` when it is
    /// building `scripts/bundle-test.sh`'s isolated variant: the real app's
    /// plate colour is the whole point of a recognisable icon, and the test
    /// build needs to be UNMISTAKABLE at a glance in the Dock and
    /// Cmd-Tab, not just correctly TCC-isolated. Requested directly, 26 Aug
    /// ("change logo on test app"), after the two builds shared the exact
    /// same icon and were genuinely hard to tell apart at a glance.
    private static var isTestBuild: Bool {
        ProcessInfo.processInfo.environment["VOICE_DISPATCH_TEST_ICON"] != nil
    }

    static func iconImage(pixels: CGFloat) -> NSImage {
        let unit = pixels / 1024
        return NSImage(size: NSSize(width: pixels, height: pixels),
                       flipped: false) { _ in
            let inset = (1024 - 824) / 2 * unit
            let plate = NSRect(x: inset, y: inset,
                               width: pixels - inset * 2, height: pixels - inset * 2)
            (isTestBuild ? StateLegend.Palette.fault : StateLegend.Palette.surface).setFill()
            NSBezierPath(roundedRect: plate, xRadius: 185.4 * unit,
                         yRadius: 185.4 * unit).fill()

            // The mark grows as the canvas shrinks, and its strokes stop
            // scaling once they reach the pixel floor. At 1024 the mark is 62%
            // of the plate with the design-grid proportions; at 16 it is 86%
            // with a wall and a bar held at 1.6 device pixels, because the
            // honest alternative — the same drawing, faithfully reduced — is
            // the grey blob this produced on its first run.
            let markSide = plate.width * (pixels <= 32 ? 0.86
                                          : pixels <= 64 ? 0.74 : 0.62)
            let scale = markSide / grid
            let floorUnits = 1.6 / scale
            let wall = max(ringWall, floorUnits)
            let bar = max(barHeight, floorUnits)
            let drawn = path(filled: false, wall: wall, bar: bar).bounds
            let transform = NSAffineTransform()
            transform.translateX(by: plate.midX - (drawn.midX * scale),
                                 yBy: plate.midY - (drawn.midY * scale))
            transform.scale(by: scale)
            transform.concat()
            // On the amber test plate, the mark's usual grey-beige has almost
            // no contrast against it (both are mid-luminance). The dark
            // surface colour that is the REAL app's plate reads clearly on
            // amber instead.
            (isTestBuild ? StateLegend.Palette.surface : StateLegend.Palette.secondary).setFill()
            path(filled: false, wall: wall, bar: bar).fill()
            return true
        }
    }

    /// Write a complete `.iconset` directory — the ladder macOS actually reads,
    /// 16 through 512 at 1x and 2x, from one drawing rather than one master PNG
    /// downsampled. `scripts/bundle.sh` runs this and hands the directory to
    /// `iconutil`.
    ///
    /// Redrawn per size on purpose: a 16pt icon resampled from 1024 is a blur,
    /// and the whole reason this mark is two shapes is that it can be redrawn
    /// small without losing anything.
    static func writeIconset(to directory: String) throws {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = CGFloat(points * scale)
                let image = iconImage(pixels: pixels)
                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "SiteMark", code: 1)
                }
                let suffix = scale == 1 ? "" : "@2x"
                let name = "icon_\(points)x\(points)\(suffix).png"
                try png.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent(name))
            }
        }
    }

    /// How many pixels of ink the mark actually lays down at `size`, and how
    /// much of that is the plate rather than the mark.
    ///
    /// Rendered and counted rather than reasoned about. The 16px app icon
    /// passed every geometric check on its first run and came out a grey blob;
    /// nothing but looking at the pixels catches that, so the drill looks.
    static func inkForTesting(size: CGFloat, filled: Bool) -> Int {
        let image = templateImage(size: size, filled: filled)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return 0 }
        var ink = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide
            where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.35 {
                ink += 1
            }
        }
        return ink
    }

    /// Does the icon at `pixels` show the MARK, not just the plate? Counts
    /// pixels that are neither the console ground nor the rounded corner's
    /// transparency — i.e. the mark's own ink.
    static func iconMarkInkForTesting(pixels: CGFloat) -> Int {
        let image = iconImage(pixels: pixels)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let mark = StateLegend.Palette.secondary.usingColorSpace(.sRGB)
        else { return 0 }
        var ink = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      c.alphaComponent > 0.5 else { continue }
                if abs(c.redComponent - mark.redComponent) < 0.12,
                   abs(c.greenComponent - mark.greenComponent) < 0.12,
                   abs(c.blueComponent - mark.blueComponent) < 0.12 {
                    ink += 1
                }
            }
        }
        return ink
    }
}
