import AppKit
import TranquilityCore

/// The graveyard: everything this machine has run lately, and one click to
/// bring any of it back.
///
/// It exists because the grid answers the wrong question for this job. The grid
/// is an instrument for NOW — who wants you, who is working, who stopped — and
/// it is deliberately small. Robert, 12 Aug: "there is a workstream that I did a
/// week ago, and I don't know which terminal tab it's in, and I don't know which
/// Claude session it's in… the only way I could possibly do it is go hunting
/// through my 60 open terminal tabs." That is a SEARCH, and a search wants a
/// list you scroll, not a panel you read.
///
/// **Built on open, never repainted while you read it.** This is the one face
/// that scrolls, and it is only safe to scroll because of that rule: the grid
/// rebuilds its rows from scratch on every content change, and doing that under
/// a scroll offset would throw the reader back to the top whenever any lamp
/// anywhere changed colour. Anyone adding a live refresh here re-creates that
/// bug — see `apply(rows:)`, which is called once per opening.
final class PastAgentsList: NSView {

    /// One row per session, in the grid's own shape: the same lamp column, the
    /// same name, the same short id. Nothing here has to be learned twice, and
    /// a session looks the same wherever you meet it.
    struct Item: Equatable {
        let row: StateLegend.SessionRow
        /// What a click does. Dead sessions come back; live ones get focus.
        let revivable: Bool
        /// Everything the filter matches against, lowercased once at build.
        let haystack: String
    }

    private let scroll = NSScrollView()
    private let stack = FlippedStack()
    private let filterField = FilterRowView()
    private var items: [Item] = []
    private var shown: [Item] = []

    var onPick: ((_ id: String, _ revivable: Bool) -> Void)?
    var onFilterChanged: (() -> Void)?

    /// What the key line says: how much you are looking at, and out of what.
    private(set) var summary = ""

    init(width: CGFloat, height: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Overlay scrollers: no reserved gutter, nothing moves when the list
        // grows past the frame, and the indicator fades when it is not needed.
        // It lands in the panel's own padding rather than over the id column —
        // there is no control on the right of a row (the lamp is the only one
        // and it is on the LEFT), so the worst case is a thin line over the
        // last characters of an id while you are actively dragging.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = stack

        // Hover is arbitrated HERE, not by each row.
        //
        // Per-row tracking areas cannot do this job in a scroll view. They fire
        // on enter and exit, and scrolling moves the CONTENT under a stationary
        // cursor — so rows slid under the pointer, took an enter, and never took
        // an exit. The symptom was every row you had scrolled past staying lit
        // at once, which is also the proof that no one was arbitrating: two rows
        // can only be hovered if nothing owns "the hovered row".
        //
        // `.inVisibleRect` was not enough on its own: it keeps a tracking rect
        // aligned with the visible area, and still says nothing about who is
        // under the mouse after a scroll nobody moved the mouse for.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        filterField.onChange = { [weak self] text in
            self?.filter(text)
            self?.onFilterChanged?()
        }

        addSubview(filterField)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            filterField.topAnchor.constraint(equalTo: topAnchor),
            filterField.leadingAnchor.constraint(equalTo: leadingAnchor),
            filterField.widthAnchor.constraint(equalToConstant: width),
            scroll.topAnchor.constraint(equalTo: filterField.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: width),
            scroll.heightAnchor.constraint(equalToConstant: height),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Called ONCE per opening. See the type's note: this face does not
    /// refresh under the reader.
    func apply(items: [Item]) {
        self.items = items
        filterField.reset()
        filter("")
        scrollToTop()
    }

    /// Case-insensitive substring, over the name, the short id and the project
    /// directory — the three things you actually remember about a session you
    /// are trying to find again. Substring rather than fuzzy on purpose: a
    /// filter you can predict is a filter you can trust, and "mirai" matching
    /// something without those five letters in it reads as a bug.
    private func filter(_ text: String) {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        shown = needle.isEmpty ? items : items.filter { $0.haystack.contains(needle) }
        summary = needle.isEmpty
            ? "\(items.count) session\(items.count == 1 ? "" : "s") · 7 days"
            : "\(shown.count) of \(items.count)"
        rebuild()
        setHovered(nil)
        // Filtering re-answers the question, so it re-answers it from the top:
        // being left half-way down a list you just narrowed is disorienting in
        // the same way opening at the bottom was.
        scrollToTop()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, item) in shown.enumerated() {
            let row = PastRowView(item: item, target: self,
                                  action: #selector(rowTapped(_:)))
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: frame.width == 0
                ? StatusHUD.gridWidth : frame.width).isActive = true
            if index < shown.count - 1 {
                let rule = NSView()
                rule.wantsLayer = true
                rule.layer?.backgroundColor = StateLegend.Palette.hairlineSoft.cgColor
                rule.translatesAutoresizingMaskIntoConstraints = false
                rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
                stack.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            }
        }
    }

    /// One tracking area over the whole list, so exactly one row can be lit.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }
    @objc private func scrolled() { updateHover() }

    /// Who is under the pointer right now, asked of geometry rather than
    /// remembered from an event. A scroll changes the answer without any event
    /// at all, which is why this is recomputed rather than tracked.
    ///
    /// It runs on EVERY frame of a live scroll, so it has to cost nothing. The
    /// first version scanned every arranged subview and converted each one's
    /// rect — an allocation and forty-five coordinate conversions per frame,
    /// which is what made the scroll feel like it was snapping rather than
    /// moving. Rows are a fixed pitch in a flipped stack, so the row under a
    /// point is one division.
    private func updateHover() {
        guard let window, window.isVisible else { return setHovered(nil) }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(local) else { return setHovered(nil) }
        let inStack = convert(local, to: stack)
        guard let index = rowIndex(at: inStack.y),
              let row = stack.arrangedSubviews[safe: index * 2] as? PastRowView
        else { return setHovered(nil) }
        setHovered(row)
    }

    /// Rows and their separators alternate, so row `i` is arranged subview
    /// `i * 2` and occupies one pitch from the top of the flipped stack.
    private func rowIndex(at y: CGFloat) -> Int? {
        let pitch = GridRowView.height + 1
        guard y >= 0 else { return nil }
        let index = Int(y / pitch)
        // Inside the row itself rather than on the hairline under it: a pointer
        // resting on a separator belongs to neither row.
        guard index < shown.count, y - CGFloat(index) * pitch <= GridRowView.height
        else { return nil }
        return index
    }

    private weak var hovered: PastRowView?

    private func setHovered(_ row: PastRowView?) {
        guard hovered !== row else { return }
        hovered?.setHovered(false)
        row?.setHovered(true)
        hovered = row
    }

    /// The top, in a flipped document view, is y = 0 — and it has to be applied
    /// AFTER layout, or the clip view clamps the scroll against a content size
    /// it has not been told about yet and lands wherever it already was.
    private func scrollToTop() {
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func rowTapped(_ sender: NSControl) {
        guard let id = sender.identifier?.rawValue,
              let item = shown.first(where: { $0.row.id == id }) else { return }
        onPick?(id, item.revivable)
    }

    func beginFiltering() { window?.makeFirstResponder(filterField.input) }

    /// What the caret is actually painted with, read back from the live field
    /// editor rather than from the constant that set it — the drill's job is to
    /// catch AppKit handing back its own accent, which a constant cannot see.
    /// Whether the list is showing its first row. In a flipped document view
    /// the top is y = 0, which is also what makes this assertable at all.
    var isAtTopForTesting: Bool {
        stack.isFlipped && scroll.contentView.bounds.origin.y <= 0.5
    }

    var caretColourForTesting: NSColor? {
        (filterField.input.currentEditor() as? NSTextView)?.insertionPointColor
    }
}

/// The filter, as a ROW rather than a box.
///
/// Ruled 12 Aug: same placard grammar as `+ NEW AGENT` — a glyph in the lamp
/// column and text beside it. No bezel, no focus ring, no rounded search field:
/// a control that looks like a form field would be the only one on the panel,
/// and the panel is an instrument, not a form.
private final class FilterRowView: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 36
    let input = FilterField()
    var onChange: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        let glyph = NSTextField(labelWithString: "⌕")
        glyph.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        glyph.textColor = StateLegend.Palette.hint
        glyph.translatesAutoresizingMaskIntoConstraints = false

        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        input.textColor = StateLegend.Palette.ink
        input.placeholderAttributedString = NSAttributedString(
            string: "Filter",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                         .foregroundColor: StateLegend.Palette.faint])
        input.delegate = self
        input.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glyph); addSubview(input)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            input.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            input.trailingAnchor.constraint(equalTo: trailingAnchor),
            input.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func reset() { input.stringValue = "" }

    func controlTextDidChange(_ obj: Notification) { onChange?(input.stringValue) }
}

/// A stack that counts from the top.
///
/// AppKit's default coordinate origin is the BOTTOM left, so a stack view used
/// as a scroll view's document view lays its first arranged subview at the
/// bottom and `scroll(to: .zero)` scrolls to the end of the list. The list
/// opened on its oldest session every time, which reads as a bug in the sort
/// rather than as a coordinate system.
///
/// Flipping the document view is the whole fix: first row at the top, `.zero`
/// at the top, and the row index maths in `rowIndex(at:)` become the obvious
/// arithmetic instead of a subtraction from the total height.
private final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// A text field whose caret belongs to the console.
///
/// AppKit paints the insertion point in the system accent colour, which on this
/// panel is a saturated blue against a dark olive console — the loudest thing on
/// a face whose whole job is calm, blinking, for a control you are not even
/// using yet. It is also the one colour the palette reserves for something else
/// entirely: blue is the WORKING lamp, and a blinking blue mark on the panel
/// means an agent has work in hand.
///
/// The caret takes the colour of the text it is placing, which is what a caret
/// is: the position of the next glyph, not an announcement.
final class FilterField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = StateLegend.Palette.ink
        }
        return accepted
    }
}

/// A row in the list: the grid's row, plus a verb that appears under the
/// pointer.
///
/// The verb REPLACES the id on hover rather than claiming a third column. At
/// rest the row answers "which one is this"; under the pointer it answers "what
/// happens if I click". A permanent action column would cost ~78pt of name on
/// every row forever to label something you need on one.
final class PastRowView: NSControl {
    private let idLabel: NSTextField
    private let verbLabel: NSTextField
    private let highlight = NSView()

    init(item: PastAgentsList.Item, target: AnyObject, action: Selector) {
        idLabel = NSTextField(labelWithString: item.row.aux)
        // Green for a resurrection, advisory grey for a door — the same two
        // channels the card uses for the same two meanings.
        verbLabel = NSTextField(labelWithString: item.revivable ? "REVIVE ›" : "GO TO ›")
        super.init(frame: .zero)
        self.target = target
        self.action = action
        identifier = NSUserInterfaceItemIdentifier(item.row.id)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        highlight.translatesAutoresizingMaskIntoConstraints = false

        let ink = item.row.lamp.rowAlpha
        let lamp = NSView()
        lamp.translatesAutoresizingMaskIntoConstraints = false
        lamp.wantsLayer = true
        lamp.layer?.backgroundColor = item.row.lamp.fill.cgColor
        lamp.layer?.cornerRadius = StateLegend.Lamp.diameter / 2
        if let ring = item.row.lamp.ring {
            lamp.layer?.borderWidth = 1
            lamp.layer?.borderColor = ring.cgColor
        }

        let name = NSTextField(labelWithString: item.row.name)
        name.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        name.textColor = StateLegend.Palette.ink.withAlphaComponent(ink)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        idLabel.font = GridRowView.auxFont
        idLabel.textColor = StateLegend.Palette.muted.withAlphaComponent(ink)
        idLabel.alignment = .right
        idLabel.translatesAutoresizingMaskIntoConstraints = false

        verbLabel.attributedStringValue = letterspaced(
            item.revivable ? "REVIVE ›" : "GO TO ›", size: 9.5, tracking: 1.33,
            color: item.revivable ? StateLegend.Palette.ready : StateLegend.Palette.accent)
        verbLabel.alignment = .right
        verbLabel.isHidden = true
        verbLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(highlight)
        addSubview(lamp); addSubview(name); addSubview(idLabel); addSubview(verbLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: GridRowView.height),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor,
                                               constant: -GridRowView.hoverBleed),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                constant: GridRowView.hoverBleed),
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            lamp.widthAnchor.constraint(equalToConstant: StateLegend.Lamp.diameter),
            lamp.heightAnchor.constraint(equalToConstant: StateLegend.Lamp.diameter),
            lamp.leadingAnchor.constraint(equalTo: leadingAnchor),
            lamp.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: leadingAnchor,
                                          constant: GridRowView.lampColumn),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: idLabel.leadingAnchor,
                                           constant: -12),
            idLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            idLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            verbLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            verbLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Told, not tracked. The list decides who is hovered — see its own note:
    /// a row cannot know it stopped being under the pointer when the thing that
    /// moved was the scroll view and not the mouse.
    func setHovered(_ on: Bool) {
        highlight.layer?.backgroundColor = on ? StateLegend.Palette.hover.cgColor : nil
        idLabel.isHidden = on
        verbLabel.isHidden = !on
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        sendAction(action, to: target)
    }
}

/// Two placards, one row. Ruled 12 Aug: NEW AGENT and PAST AGENTS are halves of
/// one idea — putting an agent on the list, by starting it or by bringing it
/// back — and two 32pt rows for that was a row too many on a panel whose whole
/// discipline is height.
final class SplitPlacardRowView: NSView {
    static let height: CGFloat = 32

    init(width: CGFloat, target: AnyObject,
         leading: (String, String, Selector),
         trailing: (String, String, Selector)) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // Each half hugs its own outer edge — the left one reads from the
        // panel's left margin, the right one lands on its right. Left-aligning
        // both put PAST AGENTS in the middle of the row with a hole beside it,
        // which reads as a mistake rather than as a column.
        let left = PlacardHalf(title: leading.0, glyph: leading.1, alignment: .leading,
                               target: target, action: leading.2)
        let right = PlacardHalf(title: trailing.0, glyph: trailing.1, alignment: .trailing,
                                target: target, action: trailing.2)
        addSubview(left); addSubview(right)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            left.leadingAnchor.constraint(equalTo: leadingAnchor),
            left.topAnchor.constraint(equalTo: topAnchor),
            left.bottomAnchor.constraint(equalTo: bottomAnchor),
            left.widthAnchor.constraint(equalToConstant: width / 2),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            right.topAnchor.constraint(equalTo: topAnchor),
            right.bottomAnchor.constraint(equalTo: bottomAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

private final class PlacardHalf: NSControl {
    private let highlight = NSView()

    init(title: String, glyph: String, alignment: NSLayoutConstraint.Attribute,
         target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        highlight.translatesAutoresizingMaskIntoConstraints = false

        let mark = NSTextField(labelWithString: glyph)
        mark.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        mark.textColor = StateLegend.Palette.hint
        mark.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = letterspaced(
            title, size: 9.5, tracking: 1.33, color: StateLegend.Palette.hint)
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(highlight); addSubview(mark); addSubview(label)
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -4),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 4),
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // The glyph keeps the lamp column's 20pt offset from the label either
        // way, so both halves read as the same control mirrored rather than as
        // two controls that happen to share a row.
        if alignment == .trailing {
            NSLayoutConstraint.activate([
                label.trailingAnchor.constraint(equalTo: trailingAnchor),
                mark.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -11),
            ])
        } else {
            NSLayoutConstraint.activate([
                mark.leadingAnchor.constraint(equalTo: leadingAnchor),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        highlight.layer?.backgroundColor = StateLegend.Palette.hover.cgColor
    }
    override func mouseExited(with event: NSEvent) {
        highlight.layer?.backgroundColor = nil
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        sendAction(action, to: target)
    }
}


private extension Array {
    /// Index arithmetic on a list that is being rebuilt under a live pointer
    /// deserves a bounds check rather than a crash.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
