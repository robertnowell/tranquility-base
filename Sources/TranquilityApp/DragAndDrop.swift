import AppKit

/// One dragged item, already resolved to something durable. A file drag
/// carries a path; a drag out of a browser carries bitmap data with no
/// file behind it, which the app writes to disk before this reaches Core.
///
/// Hoisted out of StatusHUD (App-lane P3, 23 Aug, "leaf views out") —
/// named explicitly in the original spec. Was `StatusHUD.DroppedItem`;
/// the two references inside this file simplified to the bare name.
enum DroppedItem {
    case file(String)
    case imageData(Data, suggestedName: String)
}

/// The panel's whole surface, as a drag destination.
///
/// The surface, not a well: ruled 15 Aug — "the whole UI should be
/// draggable". A target zone would be one more thing to aim at on a panel
/// whose entire premise is that you are not looking at it carefully, and the
/// panel has nothing else a drag could mean.
///
/// Dragging needs neither key status nor activation, which is why this
/// feature costs the away-channel nothing: `.nonactivatingPanel` stays
/// exactly as unstealable as it was, and no gesture changes meaning.
final class DropSurfaceView: NSView {
    /// Who would receive a drop right now, or nil to refuse the drag. Asked
    /// on entry rather than assumed: a drag invited onto a panel with no
    /// resolvable session is a promise the app cannot keep, and "drop here"
    /// followed by "nothing to reply to" is worse than no invitation at all.
    var canAccept: (() -> String?)?
    var onDrop: (([DroppedItem]) -> Bool)?
    /// Nil = the drag left or landed; non-nil = it is over us, addressed to
    /// this label.
    var onDragTargetChanged: ((String?) -> Void)?

    /// Everything a drop can carry that we know what to do with. Registered
    /// once at build; `.fileURL` covers Finder and most apps, the image types
    /// cover a drag straight out of a browser, which carries no file at all.
    static let acceptedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .tiff, .png]

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let target = canAccept?(), !items(from: sender).isEmpty else {
            onDragTargetChanged?(nil)
            return []
        }
        onDragTargetChanged?(target)
        return .copy
    }

    /// AppKit asks this repeatedly while the pointer moves inside us. It must
    /// keep returning `.copy` or the cursor reverts to the no-drop badge
    /// halfway across the panel, which reads as "this bit is not a target".
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canAccept?() == nil ? [] : .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragTargetChanged?(nil)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        // The overlay's one guaranteed teardown. `draggingExited` does NOT
        // fire when a drop is performed, and a dropped file that left the
        // invitation on screen would look like the drop never took.
        onDragTargetChanged?(nil)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        canAccept?() != nil && !items(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let dropped = items(from: sender)
        guard !dropped.isEmpty else { return false }
        return onDrop?(dropped) ?? false
    }

    /// Files first, bitmap second. A Finder drag advertises both a file URL
    /// and a preview image; taking the image would copy a file that already
    /// has a perfectly good path, and hand the session a name like
    /// "pasted-3f2a.png" instead of its own.
    private func items(from sender: any NSDraggingInfo) -> [DroppedItem] {
        let board = sender.draggingPasteboard
        if let urls = board.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map { .file($0.path) }
        }
        // A drag with no file behind it: PNG if offered, else the TIFF every
        // AppKit drag carries, re-encoded so what lands on disk is a format
        // anything downstream can open.
        if let png = board.data(forType: .png) {
            return [.imageData(png, suggestedName: "png")]
        }
        if let tiff = board.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return [.imageData(png, suggestedName: "png")]
        }
        return []
    }
}

/// The drop tray's chips: one row per staged file, above the action row.
///
/// A vertical list rather than wrapped pills, for the reason the grid is a
/// list: filenames are long and a wrapped row reflows unpredictably as the
/// set changes, while rows only ever grow downward — the geometry the panel
/// already handles by anchoring its top edge.
final class TrayRowView: NSStackView {
    /// Per-path, never clear-all (a cross that took files you did not point
    /// at is the surprise this whole feature exists to avoid).
    var onRemove: ((String) -> Void)?

    /// What is drawn right now, so `apply` can skip identical repaints —
    /// render() runs on every tick and rebuilding subviews under the pointer
    /// would kill the hover state on the ✕ you are reaching for.
    private(set) var paths: [String] = []

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 3
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ next: [String]) {
        guard next != paths else { return }
        paths = next
        removeAllArrangedSubviews()
        for path in next {
            let row = ChipRow(path: path)
            row.onRemove = { [weak self] in self?.onRemove?(path) }
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 348).isActive = true
        }
    }

    /// For the drill: the names as drawn, not the paths handed in.
    var displayedNamesForTesting: [String] {
        arrangedSubviews.compactMap { ($0 as? ChipRow)?.displayName }
    }

    /// The stack's own count, not the rows'. A view removed from the tree but
    /// left in the arrangement is invisible to `displayedNamesForTesting` and
    /// visible here, which is the difference the teardown fix is about.
    var arrangedSubviewCountForTesting: Int { arrangedSubviews.count }

    var removeButtonsForTesting: [ConsoleButton] {
        arrangedSubviews.compactMap { ($0 as? ChipRow)?.removeButton }
    }

    private final class ChipRow: NSView {
        var onRemove: (() -> Void)?
        let displayName: String
        let removeButton: ConsoleButton

        init(path: String) {
            displayName = (path as NSString).lastPathComponent
            removeButton = ConsoleButton(title: StateLegend.Glyph.denied,
                                         target: nil, action: nil)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            // The paperclip is the one glyph here that is not from the state
            // legend: the legend's marks all mean something about a SESSION,
            // and a staged file is a fact about the message instead.
            // ONE label, mark and name together, so `ChromeType.line` centres
            // the ▣ on the name's cap line by measurement. It used to be its
            // own text field pinned with `centerY`, which centres two FRAMES —
            // ascender to descender — and left the mark visibly low. A mark in
            // its own view is a mark nobody is measuring.
            let name = NSTextField(labelWithString: "")
            let markRun = ChromeType.line("▣ ", font: ChromeType.mono(ofSize: 10, weight: .regular),
                                          color: StateLegend.Lens.chrome.color)
            let nameRun = NSAttributedString(
                string: displayName,
                attributes: [.font: ChromeType.mono(ofSize: 10.5, weight: .regular),
                             .foregroundColor: StateLegend.Lens.content.color])
            let composed = NSMutableAttributedString(attributedString: markRun)
            composed.append(nameRun)
            name.attributedStringValue = composed
            name.lineBreakMode = .byTruncatingMiddle
            name.maximumNumberOfLines = 1
            // Middle truncation, and it must actually happen: a long filename
            // otherwise stretches the row past the panel and the ✕ leaves the
            // screen — the control you need most when a drop was wrong.
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            name.translatesAutoresizingMaskIntoConstraints = false

            removeButton.isBordered = false
            removeButton.font = ChromeType.mono(ofSize: 10, weight: .medium)
            // The one control on the panel that already advertised itself (it
            // has carried a pointing hand since the tray shipped), so it is the
            // one that must not be the exception now there is a standard.
            removeButton.reink = { [weak removeButton] color in
                removeButton?.attributedTitle = NSAttributedString(
                    string: StateLegend.Glyph.denied,
                    attributes: [
                        .font: ChromeType.mono(ofSize: 10, weight: .medium),
                        .foregroundColor: color,
                    ])
            }
            removeButton.restingInk = StateLegend.Lens.chrome.color
            removeButton.target = self
            removeButton.action = #selector(removeTapped)
            removeButton.translatesAutoresizingMaskIntoConstraints = false

            addSubview(name); addSubview(removeButton)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 16),
                name.leadingAnchor.constraint(equalTo: leadingAnchor),
                name.centerYAnchor.constraint(equalTo: centerYAnchor),
                name.trailingAnchor.constraint(lessThanOrEqualTo: removeButton.leadingAnchor,
                                               constant: -6),
                removeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
                removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                removeButton.widthAnchor.constraint(equalToConstant: 16),
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func removeTapped() { onRemove?() }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(removeButton.frame, cursor: .pointingHand)
        }
    }
}

/// The drop invitation: the whole surface, one sentence, shown only while a
/// drag is actually over the panel.
///
/// It covers the panel rather than joining the content stack on purpose. A
/// row appearing mid-drag would resize the window under the pointer, which
/// is reflow-on-hover — the same thing the collapsed strip's sticky note is
/// forbidden from doing, and worse here because the drag would land
/// somewhere other than where it was aimed.
final class DropOverlayView: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // The console surface at near-full opacity, so the card underneath
        // reads as covered rather than as competing with the message.
        layer?.backgroundColor = StateLegend.Palette.surface.withAlphaComponent(0.94).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = StateLegend.Palette.hairline.cgColor

        label.font = ChromeType.mono(ofSize: 11, weight: .medium)
        label.textColor = StateLegend.Lens.content.color
        label.alignment = .center
        // Wraps rather than clips. With both edges pinned, wrapping is what
        // turns "too long" into "two lines" instead of "cut off mid-word" —
        // the shipped sentence never needs it, and that is the point: the
        // layout stops depending on the sentence.
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.usesSingleLineMode = false
        // The sentence may never set the panel's width.
        //
        // Pinning both edges stopped the text running off the side and handed
        // the problem to the other end of the same wire: a label that refuses to
        // be narrower than its own text, inside an overlay pinned to all four
        // edges of the panel, is a required FLOOR under the window's width. A
        // window whose content view carries one does not go below it whatever
        // frame it is handed — so the 40pt collapsed column came out 200pt wide,
        // measured, within an hour of the invitation shipping (16 Aug). Hiding
        // the overlay does not help: a hidden view still holds its constraints,
        // and the label keeps its last string forever.
        //
        // Dropping the resistance rather than clearing the string on hide: the
        // width must not depend on remembering to blank a label, and with
        // wrapping already on, "too narrow" resolves as more lines instead of a
        // wider panel. The panel sizes the label; the label never sizes the
        // panel.
        label.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        // Pinned on BOTH sides, not centred against one. A single
        // greater-than-or-equal leading pin lets a label wider than the panel
        // grow off the right edge while its centre stays put, which is
        // precisely what shipped: the destination's name ran past the corner
        // radius with no way to read the end of it. Two pins plus wrapping
        // make an overflowing string impossible by construction rather than
        // by keeping the text short enough — the text can now be anything.
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// One fixed sentence, no destination name (ruled 16 Aug, from seeing it:
    /// "the message of the current agent is unnecessary in the drop screen
    /// and goes off the side").
    ///
    /// The name was here to catch a drop aimed at the wrong agent. In
    /// practice it could not do that job: the invitation covers the card, so
    /// the name it printed was the only identity on screen and there was
    /// nothing to check it against — an assertion, not a confirmation. The
    /// check that works is the one after the drop, where the chip sits under
    /// the card whose title names the agent, and the readback says what is
    /// riding before anything is sent.
    ///
    /// `target` is still taken and still required to be non-nil upstream: a
    /// drag with nowhere to go shows nothing at all, which is the part of the
    /// invitation that was ever load-bearing.
    func show(target: String) {
        label.stringValue = "Drop file for agent here"
        isHidden = false
    }

    var messageForTesting: String { label.stringValue }

    /// Force an arbitrary string in, so the drill can prove the CONSTRAINTS
    /// hold rather than proving the shipped wording happens to be short.
    func showForTesting(_ text: String) {
        label.stringValue = text
        isHidden = false
    }

    /// Does the text sit inside the panel, both edges? The ink, not the
    /// frame: a label frame can be clipped to bounds while the glyphs it
    /// draws still run past them.
    var textFitsForTesting: Bool {
        let ink = label.attributedStringValue.boundingRect(
            with: NSSize(width: label.bounds.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return label.frame.minX >= 0
            && label.frame.maxX <= bounds.width + 0.5
            && ink.width <= label.bounds.width + 0.5
    }

    /// Invisible to the mouse: an overlay that hit-tests would swallow the
    /// drag it exists to advertise.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
