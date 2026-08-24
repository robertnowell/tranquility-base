import AppKit
import TranquilityCore

/// A bare hover rectangle. `Controls` owns its own tracking rect rather than
/// borrowing the footer's: the footer spans the whole grid width, and hovering
/// the app's name in the opposite corner is not hovering a control.
private final class HoverBox: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .activeAlways, like the grid rows'. The panel is a .nonactivatingPanel
        // and never becomes key — .activeInKeyWindow would simply never fire.
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// The word `Controls`, wherever a face has a bottom line to put it on.
///
/// Ruled 18 Aug: the gestures do not stop existing when the grid does. The word
/// lived in the grid footer and nowhere else, so the moment a card took the
/// stage — the face you are on when a gesture is most likely to be the next
/// thing you do — the only place that names the chords was gone. One class, so
/// the hover behaviour, the ink tiers and the type cannot drift between the two
/// rows that host it; two instances, because they are two rows.
///
/// It sits in the CENTRE of its row on both faces. The card's bottom line
/// already spends both edges (OPEN HUB left, GO TO AGENT right) and the middle
/// is the only free space; putting the grid's copy anywhere else would make the
/// same word move when the face changed, which is how a permanent affordance
/// reads as a different thing each time.
final class ControlsWordView: NSView {
    var onHover: ((Bool) -> Void)?
    /// For the drill: what the word is actually drawn with.
    private(set) var wordValue = NSAttributedString()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let word = NSTextField(labelWithString: "")
        wordValue = StateLegend.BottomLine.quiet(StateLegend.controlsTitle)
        word.attributedStringValue = wordValue
        word.translatesAutoresizingMaskIntoConstraints = false

        let box = HoverBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(word)
        box.onHover = { [weak self] hovering in
            // One ink tier under the cursor — `hint` to `ink`, both above their
            // floors, so the change is a confirmation and never the difference
            // between legible and not.
            word.attributedStringValue = StateLegend.BottomLine.quiet(
                StateLegend.controlsTitle,
                color: hovering ? StateLegend.Palette.ink : StateLegend.Palette.hint)
            self?.onHover?(hovering)
        }

        addSubview(box)
        NSLayoutConstraint.activate([
            // The target is bigger than the word (ruled 18 Aug: "the controls
            // hover area on the spoken page is too small"). On the grid the
            // footer lends it a 14pt strip and it feels right; in a card's
            // action row the view hugs its own label, so the hittable area was
            // exactly the glyphs — about 8pt tall and not much wider than the
            // word — and finding it was a hunt. 8pt of slack on each side and a
            // 20pt floor makes it the same size target on both faces, which is
            // the point: one affordance, one feel.
            word.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            word.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            word.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            // 20 is the target SIZE, exactly — not a floor.
            //
            // As `>=`, with the box pinned to all four edges, this view had no
            // opinion about its own height: the constraint system was left with
            // a degree of freedom, and in a stack with vertical slack the view
            // took the slack. Measured 19 Aug over repeated runs of one
            // unchanged binary, the same card laid this out at 20pt on some
            // launches and 113pt on others — inside an action row that grew
            // from 25pt to 125pt with it — so the word either sat under the
            // body where it belongs or floated sixty points below it, and which
            // one you got was a coin flip.
            //
            // Required, because the ruling that set the 20 set a size and not a
            // minimum: "8pt of slack on each side and a 20pt floor makes it the
            // same size target on both faces, which is the point: one
            // affordance, one feel." A target that is sometimes five times its
            // ruled height is not one feel, and a hover area that moves between
            // launches is worse than a small one.
            box.heightAnchor.constraint(equalToConstant: 20),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.topAnchor.constraint(equalTo: topAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The grid's bottom line: `Controls` in the middle, `Tranquility Base` at the
/// right. Same size and same ink — the difference between them is that one
/// answers the cursor.
final class GridFooterView: NSView {
    /// Shorter than a grid row on purpose: a rule-under-the-page line, not a
    /// row you might mistake for a session.
    static let height: CGFloat = 14

    /// True on enter, false on exit — for `Controls` only.
    var onControlsHover: ((Bool) -> Void)?
    /// The signature was tapped. The panel's one door to the project itself
    /// rather than to an agent.
    var onWordmark: (() -> Void)?
    /// The hover target, exposed so the note can be hung above the row that
    /// actually owns the word rather than above a hard-coded one.
    let controls = ControlsWordView()
    /// The signature, exposed for the same reason `controls` is: a door that
    /// silently stops being a door is the failure this panel keeps having, and
    /// a drill cannot assert what it cannot reach.
    let mark = DoorLabel(labelWithString: "")

    init(width: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        controls.onHover = { [weak self] in self?.onControlsHover?($0) }

        // A `DoorLabel` rather than a label, so the signature answers the
        // pointer the way everything else on the panel does — the cursor says
        // it is a control, the ink says the pointer is on it. Both come with
        // the type; all this has to declare is that it IS a door.
        mark.attributedStringValue = StateLegend.BottomLine.quiet(StateLegend.wordmark)
        mark.isADoor = true
        mark.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(wordmarkTapped)))
        mark.translatesAutoresizingMaskIntoConstraints = false

        addSubview(controls); addSubview(mark)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: Self.height),
            controls.centerXAnchor.constraint(equalTo: centerXAnchor),
            controls.topAnchor.constraint(equalTo: topAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor),
            mark.trailingAnchor.constraint(equalTo: trailingAnchor),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func wordmarkTapped() { onWordmark?() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The sticky note behind `Controls`: the chords the key line used to spell out
/// along the bottom of every grid, now shown only when asked for.
final class ControlsNoteView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // One step up from the surface — the same lift the grid rows use for
        // hover, so the note reads as the panel raising a corner of itself
        // rather than a foreign window arriving on top of it.
        layer?.backgroundColor = StateLegend.Palette.hover.cgColor
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = StateLegend.Palette.hairline.cgColor

        let font = ChromeType.mono(ofSize: 9.5, weight: .regular)
        // ONE chord column, sized to the widest chord — the rule the grid's
        // callsign column already follows. Per-line widths would start every
        // meaning at its own x, and a three-line rag is what made the old
        // single-line key line read as a run-on.
        let chordWidth = StateLegend.controlsNote
            .map { ceil(($0.chord as NSString)
                .size(withAttributes: [.font: font]).width) }
            .max() ?? 0

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rows.translatesAutoresizingMaskIntoConstraints = false

        for entry in StateLegend.controlsNote {
            // Through the composer: these rows are nothing BUT marks beside
            // words — "⌃ Ctrl + ⌥ Option" — which makes them the last place
            // that should be setting a plain string.
            let chord = NSTextField(labelWithString: "")
            chord.attributedStringValue = ChromeType.line(
                entry.chord, font: font, color: StateLegend.Palette.ink)
            chord.font = font
            // The chord is the thing you are here to learn; the gloss explains
            // it. Full ink on the key, hint on the words.
            chord.textColor = StateLegend.Palette.ink
            chord.translatesAutoresizingMaskIntoConstraints = false
            chord.widthAnchor.constraint(equalToConstant: chordWidth).isActive = true

            let meaning = NSTextField(labelWithString: entry.meaning)
            meaning.font = font
            meaning.textColor = StateLegend.Palette.hint
            meaning.translatesAutoresizingMaskIntoConstraints = false

            let line = NSStackView(views: [chord, meaning])
            line.orientation = .horizontal
            line.alignment = .firstBaseline
            line.spacing = 10
            rows.addArrangedSubview(line)
        }

        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}
