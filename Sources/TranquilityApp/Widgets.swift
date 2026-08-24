import AppKit

/// Small, reusable view-building helpers with no state and no StatusHUD
/// dependency of their own — the destination P3 (leaf views out) moves
/// into (App-lane, docs/architecture-program.md). Named 23 Aug (P2, "name
/// the coupling before moving") ahead of the actual move: today it holds
/// the two loose top-level helpers that already had exactly this shape —
/// used from both StatusHUD.swift and PastAgentsList.swift already, which
/// is what made them safe to name first, proving the pattern before the
/// larger leaf-view migration (DroppedItem, AudioEventRow, and the rest)
/// lands on top of it.
@MainActor
enum Widgets {

    /// Small uppercase letterspaced type — the SESSIONS strip (10px, +0.16em)
    /// and the NEW SESSION placard (9.5px, +0.14em) share it.
    static func letterspaced(_ text: String, size: CGFloat, tracking: CGFloat,
                             color: NSColor, headIndent: CGFloat = 0) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            // Chrome, like everything else that names rather than says (ruled
            // 18 Aug). This was the system font, which is why AGENTS and NEW AGENT
            // read as visitors on a monospaced panel — the letterspacing was doing
            // the work of looking deliberate while the face disagreed with every
            // row beneath it.
            .font: StateLegend.Face.chrome(size),
            .kern: tracking,
            .foregroundColor: color,
        ]
        // For a placard that shares its row with a control to its LEFT (the list
        // face's back chevron): the label's frame still spans the row, but the
        // text starts clear of the control. An indent in the string rather than a
        // second leading constraint, because the label lives in the content stack
        // and its frame is not this call's to move (observed 13 Aug: the chevron
        // painted over "PAST AGENTS"'s first glyphs).
        if headIndent > 0 {
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = headIndent
            style.headIndent = headIndent
            attributes[.paragraphStyle] = style
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// A placard: the state's mark and its word, on one line.
    ///
    /// The string's symbol glyphs are optically corrected. ◀/▶ are not in
    /// SF Mono; the fallback font's triangle renders larger and off-baseline
    /// against the placard's 10pt mono caps (Robert's screenshot, 06 Aug — the
    /// "◀ SOLUTION" rung pill). The glyph run is drawn smaller with a baseline
    /// nudge so both fonts share one optical center; letter runs keep the
    /// placard's own font. Color is explicit because attributed runs ignore the
    /// field's textColor.
    ///
    /// Every mark is centred on the cap line by measurement (`ChromeType`), not by
    /// a per-glyph nudge. The old version carried `baselineOffset: 0.8` for `◀`
    /// alone — 0.67pt low, measured — and nothing at all for `⚠`, `→` or the
    /// chevrons, half of which are not even in the monospaced font and are drawn by
    /// a fallback face with its own metrics.
    ///
    /// The marks stay three-quarters of the text size: a state mark is a
    /// punctuation-weight thing beside its word, not a second word. Only its
    /// POSITION was ever wrong.
    static func placardText(
        _ text: String, color: NSColor = StateLegend.Lens.chrome.color
    ) -> NSAttributedString {
        ChromeType.line(text, font: StateLegend.placardFont, color: color, markScale: 0.68)
    }
}
