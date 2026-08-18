import AppKit
import CoreText

/// How a glyph rides a line of text, computed rather than nudged.
///
/// Ruled 18 Aug — "all these icons are not centered against their text, it
/// looks like shit." They were not, and the reason is worth writing down
/// because it is invisible in code review and obvious on screen:
///
///  1. **A hand-tuned offset is a guess about one glyph in one font at one
///     size.** The placard's `◀` carried `baselineOffset: 0.8`, which put its
///     ink centre 0.67pt BELOW the cap centre of the word beside it. At 2×
///     that is a visible drop, and every other glyph in the vocabulary had no
///     offset at all: `‹ › × ` sit 0.40pt low, `✓ ✗` 0.20pt low.
///  2. **Half the vocabulary is not in the font we asked for.** Measured:
///     `◌`, `⚠` and `✕` return an EMPTY ink box from the monospaced system
///     font, because it does not contain them — CoreText silently falls back
///     to another face with its own metrics, which is exactly the "different
///     font" you can see. Measuring in the font we asked for tells you
///     nothing about the glyph that gets drawn.
///
/// So: resolve the font that will actually draw the character, measure its ink
/// box in THAT font, and offset the baseline so the ink centre lands on the
/// text's cap centre. No constants, nothing to re-tune when a size changes,
/// and it is a number the drill can check.
enum ChromeType {

    // MARK: - The chrome face

    /// The monospaced face the whole panel is set in.
    ///
    /// Berkeley Mono when the machine has it, the system's monospaced face
    /// otherwise — and **the font is never shipped with the app**. Its licence
    /// does not permit redistribution and the vendor's commercial tiers are
    /// explicitly not compatible with open-source applications, so the repo
    /// carries no font file and installs nothing. This is the same courtesy a
    /// terminal extends: if you have licensed it and installed it, your tools
    /// use it; if you have not, nothing is missing.
    ///
    /// Nothing else in the panel needs to know. Every measurement that matters
    /// — the cap band, each mark's ink, the size a mark has to be to match it —
    /// is taken from the face at runtime (see `inkMetrics`), so a face with a
    /// different cap height, a different set of marks and a different weight
    /// ladder lands correctly without a single constant changing.
    ///
    /// `TB_MONO=system` forces the system face, for comparing the two.
    static func mono(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        guard let family = preferredFamily else {
            return .monospacedSystemFont(ofSize: size, weight: weight)
        }
        // Berkeley Mono ships Regular and Bold and nothing between, so the
        // panel's five weights land on two. Medium stays REGULAR rather than
        // rounding up: the panel spends weight on one distinction only — a door
        // versus a word — and it already spends ink on the same one. Rounding
        // medium to bold would put half the chrome in bold and leave the
        // hierarchy carried by nothing.
        let bold = weight.rawValue >= NSFont.Weight.semibold.rawValue
        let name = bold ? "BerkeleyMono-Bold" : "BerkeleyMono-Regular"
        return NSFont(name: name, size: size)
            ?? NSFontManager.shared.font(withFamily: family,
                                         traits: bold ? .boldFontMask : [],
                                         weight: bold ? 9 : 5, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Resolved once. A font lookup per label per render is a subprocess-free
    /// but not free thing, and the answer cannot change while the app runs.
    static let preferredFamily: String? = {
        guard ProcessInfo.processInfo.environment["TB_MONO"] != "system" else { return nil }
        let wanted = "Berkeley Mono"
        guard NSFont(name: "BerkeleyMono-Regular", size: 10) != nil else { return nil }
        return wanted
    }()

    /// The font CoreText will actually use to draw this character.
    static func resolvedFont(for ch: Character, in font: NSFont) -> NSFont {
        let s = String(ch) as NSString
        let resolved = CTFontCreateForString(font, s, CFRange(location: 0, length: s.length))
        return resolved as NSFont
    }

    /// The ink box of one character, in the font that will draw it.
    ///
    /// Design metrics, which is not the same thing as pixels — see `inkCentre`.
    static func inkBox(_ ch: Character, in font: NSFont) -> CGRect {
        let drawing = resolvedFont(for: ch, in: font)
        var utf16 = Array(String(ch).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(drawing, &utf16, &glyphs, utf16.count) else {
            return .zero
        }
        return CTFontGetBoundingRectsForGlyphs(drawing, .horizontal, &glyphs, nil, glyphs.count)
    }

    /// Where a character's ink ACTUALLY lands, in points above the baseline,
    /// measured by drawing it.
    ///
    /// The design box is not where the pixels go. Centring `◀` on the design
    /// box left it half a point low on screen — measured off the panel's own
    /// pose shots, 1px at 2× — because rasterising a 7.5pt triangle rounds and
    /// hints it into a pixel grid that the outline knows nothing about. Cap
    /// centre from `capHeight` has the same problem in the other direction.
    ///
    /// So this rasterises the glyph at 8× onto a known baseline and scans for
    /// ink. It is the same question the eye asks — "where is this mark on the
    /// screen" — asked of the same machinery that will answer it later.
    /// Memoised: a few dozen (character, font) pairs for the life of the app.
    static func inkCentre(_ ch: Character, in font: NSFont) -> CGFloat? {
        inkMetrics(ch, in: font)?.centre
    }

    /// Where the ink is and how tall it is, both measured by drawing.
    static func inkMetrics(_ ch: Character, in font: NSFont) -> (centre: CGFloat, height: CGFloat)? {
        let key = "\(ch)|\(font.fontName)|\(font.pointSize)"
        if let known = centres.value(key), let h = heights.value(key) { return (known, h) }
        let scale: CGFloat = 8
        let side = Int((font.pointSize * scale * 3).rounded())
        let baseline = CGFloat(side) / 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceWhite, bytesPerRow: side, bitsPerPixel: 8)
        else { return nil }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)).fill()
        let drawn = NSFont(descriptor: font.fontDescriptor,
                           size: font.pointSize * scale) ?? font
        NSAttributedString(string: String(ch), attributes: [
            .font: drawn, .foregroundColor: NSColor.white,
        ]).draw(at: NSPoint(x: font.pointSize * scale / 2,
                            y: baseline - drawn.ascender + drawn.ascender))
        NSGraphicsContext.restoreGraphicsState()

        // The draw above places the string's ORIGIN (its descender line) at y,
        // so the baseline sits `descender` above it. Scan for ink and convert
        // back to points above that baseline.
        let trueBaseline = baseline - drawn.descender
        var lowest = side, highest = -1
        for y in 0..<side {
            for x in 0..<side where rep.bitmapData?[y * side + x] ?? 0 > 40 {
                lowest = min(lowest, y); highest = max(highest, y)
                break
            }
        }
        guard highest >= 0 else { return nil }
        // Bitmap rows run top-down; the context is bottom-up. Convert.
        let inkTop = CGFloat(side - lowest)
        let inkBottom = CGFloat(side - highest - 1)
        let centre = ((inkTop + inkBottom) / 2 - trueBaseline) / scale
        let height = (inkTop - inkBottom) / scale
        centres.put(key, centre); heights.put(key, height)
        return (centre, height)
    }

    private final class Centres: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: CGFloat] = [:]
        func value(_ k: String) -> CGFloat? { lock.lock(); defer { lock.unlock() }; return known[k] }
        func put(_ k: String, _ v: CGFloat) { lock.lock(); known[k] = v; lock.unlock() }
    }
    private static let centres = Centres()
    private static let heights = Centres()

    /// The baseline offset that puts `ch`'s ink centre on `textFont`'s cap centre.
    ///
    /// Cap centre, not x-height centre and not the line's middle: the panel's
    /// chrome is set in capitals-and-lowercase where the capital is the tallest
    /// thing on the line, and a mark beside a word reads as level when it
    /// straddles the same middle the capital does.
    static func centringOffset(for ch: Character, glyphFont: NSFont,
                               textFont: NSFont) -> CGFloat {
        // Both sides measured the same way — the mark as drawn, and the cap
        // band as drawn. `H` is the reference capital because it is flat top
        // and bottom: `S` and `O` overshoot both ends and would move the target
        // by the amount of their own roundness.
        guard let mark = inkCentre(ch, in: glyphFont),
              let cap = inkCentre("H", in: textFont) else { return 0 }
        return snapped(cap - mark)
    }

    /// Rounded to the device pixel, because the text system rounds it anyway.
    ///
    /// The last half point of the ◀ came from here, and it took the panel's own
    /// pose shots to see it: the computed offset was 1.41pt, which on a 2×
    /// display is 2.82px, and AppKit lays the run out on whole pixels — so the
    /// mark sat a pixel low no matter how carefully the offset was measured.
    /// Rounding to the grid ourselves lands it on 1.5pt / 3px and leaves an
    /// error of 0.09pt, which is a twentieth of a pixel and not a thing anyone
    /// can see. The alternative — passing a precise number and hoping — is how
    /// a measurement that is right produces a picture that is wrong.
    static func snapped(_ points: CGFloat) -> CGFloat {
        let step = 1 / (NSScreen.main?.backingScaleFactor ?? 2)
        return (points / step).rounded() * step
    }

    /// Is this character a mark rather than a letter? Marks get centred;
    /// letters and digits sit on the baseline where they belong.
    static func isMark(_ ch: Character) -> Bool {
        !(ch.isLetter || ch.isNumber || ch.isWhitespace || ch.isPunctuation)
            || ch == "‹" || ch == "›"
    }

    /// The ink height of a character as drawn, in points. Rasterised, like the
    /// centre — a fallback face's design box carries padding the pixels do not.
    static func inkHeight(_ ch: Character, in font: NSFont) -> CGFloat {
        inkMetrics(ch, in: font)?.height ?? 0
    }

    /// A mark sized so it reads as the same weight as the capitals beside it.
    ///
    /// Fixed ratios do not survive contact with font fallback. `◀` lives in the
    /// monospaced face and `⚠` does not — CoreText draws it from another family
    /// entirely — so "three quarters of the text size" produced two marks of
    /// visibly different heights on the same row, and no amount of choosing a
    /// better ratio fixes a number that means different things in different
    /// faces. So the size is SOLVED for: the one whose ink height comes out at
    /// `fraction` of the cap height, found by bisection on the same measurement
    /// the centring uses. Marks then match each other, and match the capitals,
    /// whatever face they come from.
    ///
    /// 0.68 rather than 1.0 because a mark beside a word is punctuation, not a
    /// second word — it is the size the hand-tuned `◀` had arrived at, kept
    /// deliberately now that it applies to the whole vocabulary.
    static func markFont(for ch: Character, textFont: NSFont,
                         fraction: CGFloat = 0.68) -> NSFont {
        let key = "mark|\(ch)|\(textFont.fontName)|\(textFont.pointSize)|\(fraction)"
        if let known = sizes.value(key) {
            return NSFont(descriptor: textFont.fontDescriptor, size: known) ?? textFont
        }
        let target = (inkMetrics("H", in: textFont)?.height ?? textFont.capHeight) * fraction
        var low = textFont.pointSize * 0.3, high = textFont.pointSize * 2
        var best = textFont.pointSize * 0.75
        for _ in 0..<12 {
            let mid = (low + high) / 2
            let probe = NSFont(descriptor: textFont.fontDescriptor, size: mid) ?? textFont
            let h = inkHeight(ch, in: probe)
            guard h > 0 else { break }
            best = mid
            if h < target { low = mid } else { high = mid }
        }
        best = snapped(best)
        sizes.put(key, best)
        return NSFont(descriptor: textFont.fontDescriptor, size: best) ?? textFont
    }

    private static let sizes = Centres()

    /// One line of chrome: letters in `font`, every mark centred on the cap
    /// line, optionally drawn a size smaller.
    ///
    /// The one place a glyph meets a word in this app. Placards, doors and the
    /// bottom line all come through here, so a mark cannot be level on one face
    /// and low on another.
    static func line(_ text: String, font: NSFont, color: NSColor,
                     tracking: CGFloat = 0, markScale: CGFloat = 1) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            out.append(NSAttributedString(string: run, attributes: [
                .font: font, .kern: tracking, .foregroundColor: color,
            ]))
            run = ""
        }
        for ch in text {
            guard isMark(ch) else { run.append(ch); continue }
            flush()
            let glyphFont = markScale == 1 ? font
                : markFont(for: ch, textFont: font, fraction: markScale)
            out.append(NSAttributedString(string: String(ch), attributes: [
                .font: glyphFont,
                .baselineOffset: centringOffset(for: ch, glyphFont: glyphFont,
                                                textFont: font),
                .kern: tracking,
                .foregroundColor: color,
            ]))
        }
        flush()
        return out
    }

    /// How far a mark drawn in its OWN VIEW must move to sit on the cap line of
    /// the words beside it.
    ///
    /// `line(_:)` handles a mark inside a string. A mark in its own text field
    /// is the other case, and centring the two FRAMES — which is what a
    /// `centerY` constraint does — is not the same thing at all: a frame is
    /// ascender-to-descender, and where the ink sits inside it differs per
    /// glyph and per family. The chip's ▣ was frame-centred and sat visibly
    /// low, which is the same defect the placards had, in the one place the
    /// first audit did not look.
    ///
    /// Positive moves the mark UP, matching a `centerY` constraint's constant
    /// being negative in AppKit's coordinates — callers pass `-value`.
    static func capLineOffset(mark: Character, markFont: NSFont,
                              textFont: NSFont) -> CGFloat {
        guard let markInk = inkCentre(mark, in: markFont),
              let cap = inkCentre("H", in: textFont) else { return 0 }
        return snapped(cap - markInk)
    }

    /// Every mark the panel draws, for the drill. The vocabulary is defined in
    /// `StateLegend.Glyph`; this is the same set as characters, because a drill
    /// that checks a hand-copied subset proves nothing about the one you added
    /// yesterday.
    static let vocabulary: [Character] = ["◌", "◀", "▶", "⚠", "→", "●", "‹", "›", "✓", "✗"]

    /// How far off centre each mark would sit, after correction. The drill
    /// asserts this is ~zero; the log prints it so a regression names itself.
    static func centringError(font: NSFont, markScale: CGFloat = 1) -> [(Character, CGFloat)] {
        let cap = inkCentre("H", in: font) ?? font.capHeight / 2
        return vocabulary.map { ch in
            let glyphFont = markScale == 1 ? font
                : markFont(for: ch, textFont: font, fraction: markScale)
            guard let mark = inkCentre(ch, in: glyphFont) else { return (ch, 0) }
            let offset = centringOffset(for: ch, glyphFont: glyphFont, textFont: font)
            return (ch, mark + offset - cap)
        }
    }
}
