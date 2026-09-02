import AppKit
import TranquilityCore

/// The harness's own mark, drawn beside a name so you can see which agent you
/// are looking at without reading an id.
///
/// Ruled 01 Sep. Three placements, decided from a render rather than in code:
/// leading the title on the card, beside NEW AGENT (where it says what the "+"
/// will create, which is the one place the mark tells you something no other
/// element does), and on a grid row where the short id crossfades to it on
/// hover. Always-on row marks were tried and rejected as too busy.
///
/// ## Why the paths are generated and not hand-drawn
///
/// `SiteMark` is drawn from first principles because it is ours. These two are
/// not: they are vendor marks, and an approximation of somebody's logo is worse
/// than no logo. So the vendor `d` attributes were converted offline, arcs
/// split into 90-degree pieces with derivative-matched cubics, and emitted as
/// the calls below. The conversion is exact to four decimal places; nothing was
/// eyeballed.
///
/// Filled paths with the even-odd rule, matching `SiteMark`'s reasoning and
/// Apple's custom-symbol guidance (WWDC21): convert strokes to paths, no open
/// paths, flat fills only.
///
/// ## The alignment contract
///
/// Robert, 01 Sep, on the first render: "let's make sure the vertical alignment
/// is consistently correct, it should match the line height... on the new agent
/// it's super out of alignment."
///
/// It was, and not by a nudge. The two marks have different geometry inside the
/// same 24-unit box:
///
///     Claude Code   ink y 5.000 to 20.000    fills  62% of the box
///     Codex         ink y 0.000 to 24.000    fills 100% of the box
///
/// At equal box size the Codex mark renders 1.6x more ink, and the Claude mark
/// sits half a unit low on top of that. Sizing them identically could not look
/// right. Three corrections, all arithmetic:
///
///   1. each path is normalised to ITS OWN INK, so its bounds are the mark
///   2. `size(forCapHeight:)` scales by ink height, so both render the same
///      optical size despite the 62/100 difference
///   3. `baselineOffset` centres the ink on the CAP-HEIGHT midpoint, not on the
///      line box. A line box reserves descender space that capitals never use,
///      and centring on it is exactly why NEW AGENT read low.
///
/// All three are numbers, so `HarnessMarkDrills` asserts them rather than
/// leaving it to the eye that got it wrong the first time.
enum HarnessMark {

    /// Ruled 01 Sep: 75 percent. Loud enough to identify, quiet enough that it
    /// never competes with the lamp, which is the row's one real signal.
    static let opacity: CGFloat = 0.75

    /// Ink box 24.000 x 15.000, normalised to its own origin, y up.
    static let claudeCodeInk = CGSize(width: 24.0000, height: 15.0000)

    private static func claudeCodePath() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: CGPoint(x: 20.9980, y: 9.0510))
        p.line(to: CGPoint(x: 24.0000, y: 9.0510))
        p.line(to: CGPoint(x: 24.0000, y: 5.9490))
        p.line(to: CGPoint(x: 21.0000, y: 5.9490))
        p.line(to: CGPoint(x: 21.0000, y: 2.9210))
        p.line(to: CGPoint(x: 19.5130, y: 2.9210))
        p.line(to: CGPoint(x: 19.5130, y: 0.0000))
        p.line(to: CGPoint(x: 18.0000, y: 0.0000))
        p.line(to: CGPoint(x: 18.0000, y: 2.9210))
        p.line(to: CGPoint(x: 16.5130, y: 2.9210))
        p.line(to: CGPoint(x: 16.5130, y: 0.0000))
        p.line(to: CGPoint(x: 15.0000, y: 0.0000))
        p.line(to: CGPoint(x: 15.0000, y: 2.9210))
        p.line(to: CGPoint(x: 9.0000, y: 2.9210))
        p.line(to: CGPoint(x: 9.0000, y: 0.0000))
        p.line(to: CGPoint(x: 7.4880, y: 0.0000))
        p.line(to: CGPoint(x: 7.4880, y: 2.9210))
        p.line(to: CGPoint(x: 6.0000, y: 2.9210))
        p.line(to: CGPoint(x: 6.0000, y: 0.0000))
        p.line(to: CGPoint(x: 4.4870, y: 0.0000))
        p.line(to: CGPoint(x: 4.4870, y: 2.9210))
        p.line(to: CGPoint(x: 3.0000, y: 2.9210))
        p.line(to: CGPoint(x: 3.0000, y: 5.9500))
        p.line(to: CGPoint(x: 0.0000, y: 5.9500))
        p.line(to: CGPoint(x: 0.0000, y: 9.0500))
        p.line(to: CGPoint(x: 3.0000, y: 9.0500))
        p.line(to: CGPoint(x: 3.0000, y: 15.0000))
        p.line(to: CGPoint(x: 20.9980, y: 15.0000))
        p.line(to: CGPoint(x: 20.9980, y: 9.0510))
        p.close()
        p.move(to: CGPoint(x: 6.0000, y: 9.0510))
        p.line(to: CGPoint(x: 7.4880, y: 9.0510))
        p.line(to: CGPoint(x: 7.4880, y: 11.8980))
        p.line(to: CGPoint(x: 6.0000, y: 11.8980))
        p.line(to: CGPoint(x: 6.0000, y: 9.0510))
        p.close()
        p.move(to: CGPoint(x: 16.5100, y: 9.0510))
        p.line(to: CGPoint(x: 18.0000, y: 9.0510))
        p.line(to: CGPoint(x: 18.0000, y: 11.8980))
        p.line(to: CGPoint(x: 16.5100, y: 11.8980))
        p.line(to: CGPoint(x: 16.5100, y: 9.0510))
        p.line(to: CGPoint(x: 16.5100, y: 9.0510))
        p.close()
        p.windingRule = .evenOdd
        return p
    }

    /// Ink box 24.000 x 24.001, normalised to its own origin, y up.
    static let codexInk = CGSize(width: 24.0003, height: 24.0014)

    private static func codexPath() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: CGPoint(x: 8.0857, y: 23.5431))
        p.curve(to: CGPoint(x: 11.1317, y: 23.9581), controlPoint1: CGPoint(x: 9.0438, y: 23.9368), controlPoint2: CGPoint(x: 10.1032, y: 24.0812))
        p.curve(to: CGPoint(x: 14.6957, y: 22.2581), controlPoint1: CGPoint(x: 12.4647, y: 23.8051), controlPoint2: CGPoint(x: 13.6527, y: 23.2381))
        p.curve(to: CGPoint(x: 14.8027, y: 22.2291), controlPoint1: CGPoint(x: 14.7237, y: 22.2316), controlPoint2: CGPoint(x: 14.7652, y: 22.2204))
        p.curve(to: CGPoint(x: 18.8637, y: 21.8631), controlPoint1: CGPoint(x: 16.2107, y: 22.5751), controlPoint2: CGPoint(x: 17.5647, y: 22.4531))
        p.line(to: CGPoint(x: 18.9267, y: 21.8331))
        p.line(to: CGPoint(x: 19.0807, y: 21.7571))
        p.curve(to: CGPoint(x: 21.9987, y: 18.5591), controlPoint1: CGPoint(x: 20.4377, y: 21.0541), controlPoint2: CGPoint(x: 21.4107, y: 19.9871))
        p.curve(to: CGPoint(x: 22.4197, y: 16.4331), controlPoint1: CGPoint(x: 22.2767, y: 17.8801), controlPoint2: CGPoint(x: 22.4167, y: 17.1711))
        p.curve(to: CGPoint(x: 22.2397, y: 14.8021), controlPoint1: CGPoint(x: 22.4393, y: 15.8845), controlPoint2: CGPoint(x: 22.3784, y: 15.3332))
        p.curve(to: CGPoint(x: 22.2797, y: 14.6471), controlPoint1: CGPoint(x: 22.2261, y: 14.7481), controlPoint2: CGPoint(x: 22.2417, y: 14.6877))
        p.curve(to: CGPoint(x: 23.8577, y: 11.7561), controlPoint1: CGPoint(x: 23.0608, y: 13.8553), controlPoint2: CGPoint(x: 23.6142, y: 12.8414))
        p.curve(to: CGPoint(x: 22.6747, y: 6.6161), controlPoint1: CGPoint(x: 24.2427, y: 9.8551), controlPoint2: CGPoint(x: 23.8477, y: 8.1411))
        p.line(to: CGPoint(x: 22.4927, y: 6.3961))
        p.curve(to: CGPoint(x: 19.5587, y: 4.5451), controlPoint1: CGPoint(x: 21.7213, y: 5.5128), controlPoint2: CGPoint(x: 20.6881, y: 4.8609))
        p.curve(to: CGPoint(x: 19.4507, y: 4.4431), controlPoint1: CGPoint(x: 19.5093, y: 4.5309), controlPoint2: CGPoint(x: 19.4678, y: 4.4916))
        p.curve(to: CGPoint(x: 18.4637, y: 2.4511), controlPoint1: CGPoint(x: 19.1957, y: 3.7071), controlPoint2: CGPoint(x: 18.9397, y: 3.0791))
        p.curve(to: CGPoint(x: 13.5157, y: 0.0001), controlPoint1: CGPoint(x: 17.2647, y: 0.8691), controlPoint2: CGPoint(x: 15.5017, y: -0.0109))
        p.curve(to: CGPoint(x: 9.3057, y: 1.7361), controlPoint1: CGPoint(x: 11.9327, y: 0.0081), controlPoint2: CGPoint(x: 10.5297, y: 0.5871))
        p.curve(to: CGPoint(x: 9.1657, y: 1.7681), controlPoint1: CGPoint(x: 9.2688, y: 1.7700), controlPoint2: CGPoint(x: 9.2137, y: 1.7826))
        p.curve(to: CGPoint(x: 7.5617, y: 1.5831), controlPoint1: CGPoint(x: 8.6477, y: 1.6011), controlPoint2: CGPoint(x: 8.1257, y: 1.5771))
        p.curve(to: CGPoint(x: 4.9667, y: 2.2051), controlPoint1: CGPoint(x: 6.6645, y: 1.5903), controlPoint2: CGPoint(x: 5.7697, y: 1.8048))
        p.curve(to: CGPoint(x: 2.8207, y: 3.9861), controlPoint1: CGPoint(x: 4.1264, y: 2.6219), controlPoint2: CGPoint(x: 3.3853, y: 3.2370))
        p.curve(to: CGPoint(x: 2.2697, y: 4.8071), controlPoint1: CGPoint(x: 2.6177, y: 4.2551), controlPoint2: CGPoint(x: 2.4167, y: 4.5081))
        p.curve(to: CGPoint(x: 1.7747, y: 6.0901), controlPoint1: CGPoint(x: 2.0671, y: 5.2190), controlPoint2: CGPoint(x: 1.9012, y: 5.6489))
        p.curve(to: CGPoint(x: 1.7577, y: 9.1541), controlPoint1: CGPoint(x: 1.5103, y: 7.0880), controlPoint2: CGPoint(x: 1.5044, y: 8.1533))
        p.curve(to: CGPoint(x: 1.7657, y: 9.2281), controlPoint1: CGPoint(x: 1.7659, y: 9.1777), controlPoint2: CGPoint(x: 1.7687, y: 9.2033))
        p.curve(to: CGPoint(x: 1.7287, y: 9.2921), controlPoint1: CGPoint(x: 1.7608, y: 9.2527), controlPoint2: CGPoint(x: 1.7476, y: 9.2756))
        p.curve(to: CGPoint(x: 0.3487, y: 11.4941), controlPoint1: CGPoint(x: 1.1148, y: 9.9131), controlPoint2: CGPoint(x: 0.6399, y: 10.6708))
        p.curve(to: CGPoint(x: 0.0157, y: 13.0831), controlPoint1: CGPoint(x: 0.1555, y: 12.0020), controlPoint2: CGPoint(x: 0.0427, y: 12.5404))
        p.curve(to: CGPoint(x: 0.2037, y: 15.2151), controlPoint1: CGPoint(x: -0.0325, y: 13.7978), controlPoint2: CGPoint(x: 0.0311, y: 14.5199))
        p.curve(to: CGPoint(x: 2.7807, y: 18.7081), controlPoint1: CGPoint(x: 0.6537, y: 16.6991), controlPoint2: CGPoint(x: 1.5127, y: 17.8631))
        p.curve(to: CGPoint(x: 3.5827, y: 19.1461), controlPoint1: CGPoint(x: 3.0627, y: 18.8961), controlPoint2: CGPoint(x: 3.3307, y: 19.0421))
        p.curve(to: CGPoint(x: 4.4437, y: 19.4501), controlPoint1: CGPoint(x: 3.8687, y: 19.2661), controlPoint2: CGPoint(x: 4.1557, y: 19.3661))
        p.curve(to: CGPoint(x: 4.5307, y: 19.5371), controlPoint1: CGPoint(x: 4.4847, y: 19.4623), controlPoint2: CGPoint(x: 4.5186, y: 19.4961))
        p.curve(to: CGPoint(x: 5.6347, y: 21.6901), controlPoint1: CGPoint(x: 4.7484, y: 20.3194), controlPoint2: CGPoint(x: 5.1264, y: 21.0568))
        p.curve(to: CGPoint(x: 8.0857, y: 23.5431), controlPoint1: CGPoint(x: 6.3147, y: 22.5361), controlPoint2: CGPoint(x: 7.1317, y: 23.1541))
        p.close()
        p.move(to: CGPoint(x: 7.2817, y: 15.6931))
        p.curve(to: CGPoint(x: 6.1242, y: 16.0086), controlPoint1: CGPoint(x: 7.0613, y: 16.0787), controlPoint2: CGPoint(x: 6.5098, y: 16.2290))
        p.curve(to: CGPoint(x: 5.8087, y: 14.8511), controlPoint1: CGPoint(x: 5.7386, y: 15.7882), controlPoint2: CGPoint(x: 5.5883, y: 15.2367))
        p.line(to: CGPoint(x: 7.5027, y: 11.8861))
        p.line(to: CGPoint(x: 5.8147, y: 9.0381))
        p.curve(to: CGPoint(x: 6.1305, y: 7.9062), controlPoint1: CGPoint(x: 5.6103, y: 8.6568), controlPoint2: CGPoint(x: 5.7582, y: 8.1265))
        p.curve(to: CGPoint(x: 7.2747, y: 8.1741), controlPoint1: CGPoint(x: 6.5028, y: 7.6859), controlPoint2: CGPoint(x: 7.0389, y: 7.8114))
        p.line(to: CGPoint(x: 9.2147, y: 11.4461))
        p.curve(to: CGPoint(x: 9.2217, y: 12.3001), controlPoint1: CGPoint(x: 9.3669, y: 11.7027), controlPoint2: CGPoint(x: 9.3696, y: 12.0411))
        p.line(to: CGPoint(x: 7.2817, y: 15.6931))
        p.line(to: CGPoint(x: 7.2817, y: 15.6931))
        p.close()
        p.move(to: CGPoint(x: 12.7277, y: 9.4531))
        p.curve(to: CGPoint(x: 11.9292, y: 8.6056), controlPoint1: CGPoint(x: 12.3008, y: 9.4277), controlPoint2: CGPoint(x: 11.9292, y: 9.0333))
        p.curve(to: CGPoint(x: 12.7277, y: 7.7581), controlPoint1: CGPoint(x: 11.9292, y: 8.1779), controlPoint2: CGPoint(x: 12.3008, y: 7.7835))
        p.line(to: CGPoint(x: 17.5757, y: 7.7581))
        p.curve(to: CGPoint(x: 18.3835, y: 8.6061), controlPoint1: CGPoint(x: 18.0060, y: 7.7790), controlPoint2: CGPoint(x: 18.3835, y: 8.1753))
        p.curve(to: CGPoint(x: 17.5757, y: 9.4541), controlPoint1: CGPoint(x: 18.3835, y: 9.0369), controlPoint2: CGPoint(x: 18.0060, y: 9.4332))
        p.line(to: CGPoint(x: 12.7277, y: 9.4541))
        p.line(to: CGPoint(x: 12.7277, y: 9.4531))
        p.close()
        p.windingRule = .evenOdd
        return p
    }

    // MARK: - The public surface

    /// The ink box of a harness's mark, in its own units.
    static func ink(for harness: String) -> CGSize {
        harness == CodexAdapter().id ? codexInk : claudeCodeInk
    }

    /// The path, normalised so its bounds are exactly its ink.
    static func path(for harness: String) -> NSBezierPath {
        harness == CodexAdapter().id ? codexPath() : claudeCodePath()
    }

    /// What to draw, at this ink height. Width follows the mark's own aspect;
    /// the Claude mark is wide and short, the Codex one is square.
    static func size(height: CGFloat, harness: String) -> CGSize {
        let box = ink(for: harness)
        return CGSize(width: height * (box.width / box.height), height: height)
    }

    /// The mark as a template image of exactly `height` ink.
    static func image(height: CGFloat, harness: String) -> NSImage {
        let target = size(height: height, harness: harness)
        let image = NSImage(size: target, flipped: false) { _ in
            let p = path(for: harness)
            let t = NSAffineTransform()
            t.scale(by: target.height / ink(for: harness).height)
            p.transform(using: t as AffineTransform)
            NSColor.black.setFill()
            p.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

extension HarnessMark {
    /// A flat-tinted copy. Needed only where an image is drawn outside a
    /// control that could tint it, which on this panel is a text attachment.
    static func tinted(_ image: NSImage, with colour: NSColor) -> NSImage {
        let out = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            colour.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        out.isTemplate = false
        return out
    }
}
