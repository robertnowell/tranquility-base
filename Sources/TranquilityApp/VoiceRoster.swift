import AppKit
import TranquilityCore

/// A scroll document that hangs content from the top; without it a stack in an
/// NSScrollView anchors to the bottom and short lists float mid-air.
final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// One row of the voice roster pane (draft render ruled 05 Aug):
/// [≡ grip 16][square check 14][11][▶][11][name — flexible][category, faint].
/// The check is SQUARE — it is a checkbox; circles are the grid's session
/// lamps and the two must not read as the same species. The grip lives in the
/// left gutter so the check column is the pane's left alignment line, and it
/// exists only on roster rows: the bench below is sorted, not ordered.
final class VoiceRowView: NSControl {
    static let height: CGFloat = 34
    static let gripWidth: CGFloat = 16

    let voiceId: String
    let isOnRoster: Bool
    private let onPlay: () -> Void
    private let onToggle: () -> Void
    private let onDragStep: (VoiceRowView, Int) -> Void
    private let onDragEnd: () -> Void
    private let hairline = CALayer()
    private var dragging = false
    private var dragAccum: CGFloat = 0
    private var lastStep = 0

    init(voice: Voice, onRoster: Bool,
         onPlay: @escaping () -> Void,
         onToggle: @escaping () -> Void,
         onDragStep: @escaping (VoiceRowView, Int) -> Void,
         onDragEnd: @escaping () -> Void) {
        self.voiceId = voice.id
        self.isOnRoster = onRoster
        self.onPlay = onPlay
        self.onToggle = onToggle
        self.onDragStep = onDragStep
        self.onDragEnd = onDragEnd
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        hairline.backgroundColor = StateLegend.Palette.hairlineSoft.cgColor
        layer?.addSublayer(hairline)

        let grip = NSTextField(labelWithString: onRoster ? "≡" : "")   // download rows never show one
        grip.font = ChromeType.mono(ofSize: 11, weight: .regular)
        grip.textColor = StateLegend.Palette.faint
        grip.translatesAutoresizingMaskIntoConstraints = false

        // A voice you do not have cannot be auditioned and cannot be cast, so it gets
        // neither control. Shipping it with a checkbox and a ▶ that opened System
        // Settings was worse than useless: a play button that does not play is a lie,
        // and a checkbox that cannot be checked is furniture.
        let isDownload = SystemVoiceCatalog.isDownloadRow(voice.id)

        let check = CheckView(on: onRoster) { [weak self] in self?.onToggle() }
        // Hidden rather than omitted, so the name column stays on the same x as every
        // other row. Dropping the view would shift the whole row left and misalign the
        // list against itself.
        check.isHidden = isDownload

        let play = ConsoleButton(title: "▶", target: self, action: #selector(playTapped))
        play.isBordered = false
        play.font = ChromeType.mono(ofSize: 14, weight: .regular)
        play.restingInk = StateLegend.Palette.secondary
        // Invisible, not absent: the slot holds the name column's x so every row's
        // name starts on the same pixel. Putting "Get" in this slot instead pushed
        // the name right and misaligned that row against the whole list.
        play.isHidden = isDownload
        play.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: Self.concise(voice.name))
        name.font = ChromeType.mono(ofSize: 12, weight: .medium)
        // Dimmed when it is not installed — the row is an offer, not a voice you have.
        name.textColor = isDownload ? StateLegend.Palette.secondary : StateLegend.Palette.ink
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let category = NSTextField(labelWithString: voice.category)
        category.font = ChromeType.mono(ofSize: 9.5, weight: .regular)
        category.textColor = StateLegend.Palette.hint
        category.translatesAutoresizingMaskIntoConstraints = false

        // The action sits on the right, where an action belongs, rather than in the
        // preview slot where it displaced the name.
        // Drawn from the panel's own palette, not AppKit's bezel.
        //
        // `bezelStyle = .rounded` paints a LIGHT system chrome and a dark title, which
        // on this dark console rendered as near-black text on near-black fill — the
        // one control on the pane you are meant to press, and the least visible thing
        // on it. The panel guarantees its own contrast everywhere else (`surface` is
        // opaque for exactly this reason); the button now does too.
        // The one control on the panel with a box of its own, so it is the one
        // that takes rule 1 and stops: it already looks like a button, and an
        // ink step on a title sitting on its own fill would say what the fill
        // has said since it was drawn.
        let get = ConsoleButton(title: "", target: self, action: #selector(playTapped))
        get.isBordered = false
        get.wantsLayer = true
        get.layer?.backgroundColor = StateLegend.Palette.hairline.cgColor
        get.layer?.cornerRadius = 5
        get.attributedTitle = NSAttributedString(
            string: "Get",
            attributes: [
                // ink on surface is 8.39:1 — the same ink the row names use, so the
                // action is at least as legible as the thing it acts on.
                .foregroundColor: StateLegend.Palette.ink,
                .font: ChromeType.mono(ofSize: 10, weight: .semibold),
            ])
        get.translatesAutoresizingMaskIntoConstraints = false
        get.isHidden = !isDownload

        addSubview(grip); addSubview(check); addSubview(play)
        addSubview(name); addSubview(category); addSubview(get)
        NSLayoutConstraint.activate([
            get.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            get.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
            grip.leadingAnchor.constraint(equalTo: leadingAnchor),
            grip.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.leadingAnchor.constraint(equalTo: leadingAnchor,
                                           constant: Self.gripWidth),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            play.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 11),
            play.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: play.trailingAnchor, constant: 11),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: category.leadingAnchor,
                                           constant: -10),
            category.trailingAnchor.constraint(
                equalTo: isDownload ? get.leadingAnchor : trailingAnchor,
                constant: isDownload ? -8 : -4),
            category.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        hairline.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }

    /// "Brittney - Social Media Voice - Fun, Youthful…" → "Brittney". The row
    /// names a voice; the sales copy stays in the catalog.
    static func concise(_ name: String) -> String {
        let head = name
            .components(separatedBy: CharacterSet(charactersIn: "-–—™"))
            .first?.trimmingCharacters(in: .whitespaces) ?? name
        return head.isEmpty ? name : head
    }

    @objc private func playTapped() { onPlay() }

    // ≡ drag: whole-row steps from accumulated deltaY (positive = down =
    // later index; the flipped document keeps visual and index order equal).
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isOnRoster, point.x < Self.gripWidth else { return }
        dragging = true; dragAccum = 0; lastStep = 0
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        dragAccum += event.deltaY
        let step = Int((dragAccum / Self.height).rounded())
        if step != lastStep {
            onDragStep(self, step - lastStep)
            lastStep = step
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onDragEnd()
    }
}

/// The square roster checkbox: filled console green with a ✓ when on, the
/// hover putty with a hairline ring when off. Same materials as the lamps,
/// different shape — shape is what says "you can set this".
private final class CheckView: NSControl {
    private let onToggle: () -> Void

    /// Rule 1 of the hover standard: a control says so with the cursor. A
    /// checkbox drawn by hand looks exactly as clickable as the glyph beside it,
    /// which is to say not at all.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    init(on: Bool, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 2.5
        layer?.backgroundColor = (on ? StateLegend.Palette.ready
                                     : StateLegend.Palette.hover).cgColor
        if !on {
            layer?.borderWidth = 1
            layer?.borderColor = StateLegend.Palette.hairline.cgColor
        }
        if on {
            let mark = NSTextField(labelWithString: StateLegend.Glyph.confirm)
            mark.font = ChromeType.mono(ofSize: 9, weight: .bold)
            // Punched out of the lamp, in the housing's own colour: 6.35:1
            // against `ready`. This was a hardcoded near-white, which read fine
            // on the old dark green and would have fallen to 1.88:1 on the
            // brighter one — an invisible tick, visible only at runtime, in one
            // state. Exactly the failure the "no literals outside the Palette"
            // rule exists to prevent.
            mark.textColor = StateLegend.Palette.surface
            mark.translatesAutoresizingMaskIntoConstraints = false
            addSubview(mark)
            NSLayoutConstraint.activate([
                mark.centerXAnchor.constraint(equalTo: centerXAnchor),
                mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 14),
            heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onToggle()
    }
}
