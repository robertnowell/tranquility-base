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
        /// What THIS list's right column says, when it is not what the grid's
        /// says. The grid answers "which one is this" and shows the short id;
        /// this list answers "when did I last touch it" and shows the time
        /// (ruled 19 Aug). Two faces, two questions, and the row is not
        /// rewritten to serve one of them — the list carries its own column and
        /// the grid is untouched.
        ///
        /// Nil falls back to `row.aux`, which is what the drills want: a fixture
        /// that says nothing about time keeps the shape it always had.
        let aux: String?
        /// What the pointer says, when it is not what `hoverText` would say.
        /// The id displaced from the column lands here, so nothing is lost by
        /// the swap above — see `openPastAgents`, which is the one place that
        /// knows both halves.
        let tooltip: String?

        init(row: StateLegend.SessionRow, revivable: Bool, haystack: String,
             aux: String? = nil, tooltip: String? = nil) {
            self.row = row
            self.revivable = revivable
            self.haystack = haystack
            self.aux = aux
            self.tooltip = tooltip
        }
    }

    private let scroll = NSScrollView()
    private let stack = FlippedStack()
    private let filterField = FilterRowView()
    private var items: [Item] = []
    private var shown: [Item] = []

    var onPick: ((_ id: String, _ revivable: Bool) -> Void)?
    /// A click on the LAMP COLUMN, which is the session's power switch and
    /// never navigation — see `StateLegend.lampAction(for:)`. The whole row is
    /// handed over rather than an id, because the switch's verb is a function
    /// of the lamp and the caller must read it from the same place the grid
    /// does, or the same dot means two things on two faces.
    var onLamp: ((_ row: StateLegend.SessionRow) -> Void)?
    var onFilterChanged: (() -> Void)?
    /// Right-click → "Terminate" on a LIVE row (ruled 13 Aug). Dead sessions
    /// have no process to end and get no menu — an empty menu would promise a
    /// verb this row cannot perform.
    var onTerminate: ((_ id: String, _ name: String) -> Void)?

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
            // Set on EVERY row, not only the ones with something to switch.
            // The grid's original set it on green alone, which is why the
            // column read as inert everywhere else and a dark lamp sent you to
            // a Terminal tab instead of turning the session on. A rule that
            // holds on some rows is not a rule you can learn.
            row.onLampTap = { [weak self] in self?.onLamp?(item.row) }
            // The menu item NAMES its target — "Terminate “promotions-f9”" —
            // which is the confirmation: a right-click then a click on a
            // sentence containing the right name. No dialog after that.
            if !item.revivable {
                let menu = NSMenu()
                let terminate = NSMenuItem(
                    title: "Terminate \u{201C}\(item.row.name)\u{201D}",
                    action: #selector(terminatePicked(_:)), keyEquivalent: "")
                terminate.target = self
                terminate.representedObject = item.row.id
                menu.addItem(terminate)
                row.menu = menu
            }
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

    @objc private func terminatePicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = shown.first(where: { $0.row.id == id }) else { return }
        onTerminate?(id, item.row.name)
    }

    /// For the copy drill: what the pointer would show on each row.
    var toolTipsForTesting: [String] {
        stack.arrangedSubviews.compactMap { ($0 as? PastRowView)?.toolTip }
    }

    /// For the name drill: how wide each row's NAME was actually laid out.
    /// Read from the frame, because the failure this guards is a name that is
    /// set correctly and rendered at zero points — a long stall reason in the
    /// right column squeezing it out (19 Aug).
    var nameWidthsForTesting: [(id: String, width: CGFloat)] {
        stack.arrangedSubviews.compactMap {
            guard let row = $0 as? PastRowView, let id = row.identifier?.rawValue
            else { return nil }
            return (id, row.nameWidthForTesting)
        }
    }

    /// For the lamp drill: which rows carry a switch in the lamp column.
    /// Asserted rather than assumed, because "every row" IS the ruling — a
    /// target on some rows is exactly what made the column unlearnable.
    var lampTargetsForTesting: [String] {
        stack.arrangedSubviews.compactMap {
            guard let row = $0 as? PastRowView, row.onLampTap != nil,
                  let id = row.identifier?.rawValue else { return nil }
            return id
        }
    }

    /// For the launch drill: which rows exist and whether each carries the
    /// terminate menu — asserted against liveness, never assumed from it.
    var rowsForTesting: [(id: String, hasMenu: Bool)] {
        stack.arrangedSubviews.compactMap {
            guard let row = $0 as? PastRowView, let id = row.identifier?.rawValue
            else { return nil }
            return (id, row.menu != nil)
        }
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
        glyph.font = ChromeType.mono(ofSize: 12, weight: .regular)
        glyph.textColor = StateLegend.Palette.hint
        glyph.translatesAutoresizingMaskIntoConstraints = false

        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = ChromeType.mono(ofSize: 12, weight: .regular)
        input.textColor = StateLegend.Palette.ink
        input.placeholderAttributedString = NSAttributedString(
            string: "Filter",
            attributes: [.font: ChromeType.mono(ofSize: 12, weight: .regular),
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
    /// Held so the hover can step its ink and put it back — see `setHovered`.
    private var nameLabel: NSTextField!
    private var restingName: NSColor = StateLegend.Palette.ink

    init(item: PastAgentsList.Item, target: AnyObject, action: Selector) {
        idLabel = NSTextField(labelWithString: item.aux ?? item.row.aux)
        // Green for a resurrection, advisory grey for a door — the same two
        // channels the card uses for the same two meanings.
        verbLabel = NSTextField(labelWithString: item.revivable ? "REVIVE ›" : "GO TO ›")
        super.init(frame: .zero)
        self.target = target
        self.action = action
        identifier = NSUserInterfaceItemIdentifier(item.row.id)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // The same hover as the grid, through the same function: a row that
        // said one thing on one face and another on the other would be worse
        // than one that said nothing.
        toolTip = item.tooltip ?? StateLegend.hoverText(for: item.row)

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        highlight.translatesAutoresizingMaskIntoConstraints = false

        let ink = item.row.lamp.rowAlpha
        let lamp = NSView()
        lamp.translatesAutoresizingMaskIntoConstraints = false
        lamp.wantsLayer = true
        // Same fill-vs-ring read channel as the grid (16 Aug): solid unread,
        // hollow once opened, in the state's own colour. One rule in both
        // lists, or "have I heard this" would mean something different
        // depending on which face you were looking at.
        let hollow = item.row.read == .opened && item.row.lamp.asksForYou
        lamp.layer?.backgroundColor = hollow ? NSColor.clear.cgColor
                                             : item.row.lamp.fill.cgColor
        lamp.layer?.cornerRadius = StateLegend.Lamp.diameter / 2
        if hollow {
            lamp.layer?.borderWidth = 1.5
            lamp.layer?.borderColor = item.row.lamp.fill.cgColor
        } else if let ring = item.row.lamp.ring {
            lamp.layer?.borderWidth = 1
            lamp.layer?.borderColor = ring.cgColor
        }

        // The read state travels with the row (16 Aug: "idle should have our
        // read text treatment too"). This list is where you come to FIND a
        // session, so "have I already heard this one" is worth as much here
        // as it is on the grid — and the row has carried the flag all along,
        // it was simply the grid that read it.
        //
        // It composes with `rowAlpha` rather than competing: alpha says
        // running-or-gone, the token says read-or-not, so a dead row you had
        // opened is dimmed once by each and still cannot be mistaken for a
        // live one.
        let name = NSTextField(labelWithString: item.row.name)
        name.font = ChromeType.mono(ofSize: 13, weight: .medium)
        name.textColor = (item.row.read.isAsking && item.row.lamp.asksForYou
                          ? StateLegend.Palette.ink
                          : StateLegend.Palette.restingInk).withAlphaComponent(ink)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        idLabel.font = GridRowView.auxFont
        idLabel.textColor = StateLegend.Palette.muted.withAlphaComponent(ink)
        idLabel.alignment = .right
        // The right column YIELDS to the name, and is capped besides.
        //
        // Both halves are needed and neither is enough alone. This column
        // usually holds an eight-character id, so nothing ever pushed on the
        // name — until a stopped session put its REASON here instead (16 Aug,
        // and correctly: "an id would be the one row where this column says
        // nothing useful"). A reason is a sentence. With the name at
        // `.defaultLow` compression resistance and this label at the default,
        // the sentence won every time: "silent for 24h, nothing written since
        // it started" took the whole row and the agent's name was squeezed to
        // ZERO WIDTH — the one row in the list that did not say which agent it
        // was (screenshot, 19 Aug).
        //
        // The grid never had this bug because it measures one shared column
        // across every row and caps it at `auxFraction`; the list, which builds
        // each row alone, had neither. It gets both: the cap, so a long reason
        // cannot claim more than the grid would give it, and a lower resistance
        // than the name, so the name is the last thing to lose space rather
        // than the first. What is cut off is reachable — the row's tooltip
        // carries the name and the full message, uncut (`StateLegend.hoverText`).
        idLabel.lineBreakMode = .byTruncatingTail
        idLabel.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(name.contentCompressionResistancePriority(for: .horizontal)
                                            .rawValue - 1),
            for: .horizontal)
        idLabel.translatesAutoresizingMaskIntoConstraints = false

        verbLabel.attributedStringValue = letterspaced(
            item.revivable ? "REVIVE ›" : "GO TO ›", size: 9.5, tracking: 1.33,
            color: item.revivable ? StateLegend.Palette.ready : StateLegend.Palette.accent)
        verbLabel.alignment = .right
        verbLabel.isHidden = true
        verbLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(highlight)
        nameLabel = name
        restingName = name.textColor ?? StateLegend.Palette.ink
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
            idLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor,
                                           multiplier: GridRowView.auxFraction),
            verbLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            verbLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// What the drill needs to see: the name's laid-out width. Read from the
    /// FRAME rather than from the string, because the failure mode is a name
    /// that is set correctly and rendered at zero points.
    var nameWidthForTesting: CGFloat { nameLabel.frame.width }

    /// Rule 1 of the hover standard (18 Aug): the wash says which row, the
    /// cursor says it is a control.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Told, not tracked. The list decides who is hovered — see its own note:
    /// a row cannot know it stopped being under the pointer when the thing that
    /// moved was the scroll view and not the mouse.
    func setHovered(_ on: Bool) {
        // Words only, exactly as the grid's rows — see `GridRowView.setHovered`.
        // This list has a second cue the grid does not: the id gives way to the
        // verb, so the hovered row also says what a click would DO.
        nameLabel.textColor = on ? StateLegend.hovered(restingName) : restingName
        idLabel.isHidden = on
        verbLabel.isHidden = !on
    }

    /// The lamp column, as a control — the same `lampHitWidth` at the same full
    /// row height the grid uses, so the switch is in the same place and the same
    /// size wherever you meet a session. Never falls through to the row's verb:
    /// the point of a switch is that it is not a door.
    var onLampTap: (() -> Void)?

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if let onLampTap, point.x <= GridRowView.lampHitWidth {
            onLampTap()
            return
        }
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
    private let mark = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    private var resting: [NSAttributedString] = []

    /// The hover standard, re-ruled 18 Aug: **a row washes, a word brightens.**
    ///
    /// This was a wash — a rounded fill across the whole half — because it was
    /// built beside the grid rows, which wash. But a grid row IS a region: a
    /// lamp, a name and a callsign across 352pt, where the fill tells you which
    /// row the click will land on. NEW AGENT and PAST AGENTS are two words in a
    /// strip, and a fill four times their width reads as a button that isn't
    /// there — "they have a big background hover instead of a text hover
    /// effect. That's an inconsistency."
    ///
    /// So the words brighten, exactly as `Controls` and the state pill do, and
    /// the cursor still says the placard is a control at all. The wash stays
    /// where a region needs one.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    init(title: String, glyph: String, alignment: NSLayoutConstraint.Attribute,
         target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        mark.attributedStringValue = ChromeType.line(
            glyph, font: ChromeType.mono(ofSize: 12, weight: .regular),
            color: StateLegend.Palette.hint)
        mark.translatesAutoresizingMaskIntoConstraints = false

        label.attributedStringValue = letterspaced(
            title, size: 9.5, tracking: 1.33, color: StateLegend.Palette.hint)
        label.translatesAutoresizingMaskIntoConstraints = false
        resting = [mark.attributedStringValue, label.attributedStringValue]

        addSubview(mark); addSubview(label)
        NSLayoutConstraint.activate([
            // Not a plain centerY: that centres two FRAMES, and a mark's ink
            // sits differently inside its box than a capital does inside
            // theirs. The offset is measured — see `ChromeType.capLineOffset`.
            // The mark keeps its own view here because the 20pt gutter lines up
            // with the grid's lamp column, which a merged string would lose.
            mark.centerYAnchor.constraint(
                equalTo: centerYAnchor,
                constant: -ChromeType.capLineOffset(
                    mark: Character(glyph),
                    markFont: ChromeType.mono(ofSize: 12, weight: .regular),
                    textFont: ChromeType.mono(ofSize: 9.5, weight: .regular))),
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
        mark.attributedStringValue = StateLegend.hoveredInk(resting[0])
        label.attributedStringValue = StateLegend.hoveredInk(resting[1])
    }
    override func mouseExited(with event: NSEvent) {
        mark.attributedStringValue = resting[0]
        label.attributedStringValue = resting[1]
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

/// One editable setting, as a row.
///
/// Same grammar as the list's filter and the + NEW AGENT placard: a small caps
/// label, then the value in the panel's own mono, no bezel and no focus ring.
/// A bordered NSTextField would be the only form control in the app, and the
/// panel is an instrument — the console's own answer to "type here" is a lit
/// field on a dark ground, not a box drawn around one.
///
/// Commits on Return and on losing focus, never per keystroke: this is the
/// command that starts your agents, and saving `claude --dangerous` halfway
/// through typing is a setting that is briefly wrong in a way that matters.
final class SettingRowView: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 34
    let input = FilterField()
    var onCommit: ((String) -> Void)?

    /// Set when this row picks a folder instead of taking a typed path.
    var onBrowse: (() -> Void)?

    init(width: CGFloat, label: String, placeholder: String, browsable: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(labelWithString: "")
        caption.attributedStringValue = letterspaced(
            label, size: 9.5, tracking: 1.33, color: StateLegend.Palette.hint)
        caption.translatesAutoresizingMaskIntoConstraints = false

        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = ChromeType.mono(ofSize: 11, weight: .regular)
        input.textColor = StateLegend.Palette.ink
        input.lineBreakMode = .byTruncatingHead
        input.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.font: ChromeType.mono(ofSize: 11, weight: .regular),
                         .foregroundColor: StateLegend.Palette.faint])
        input.delegate = self
        input.translatesAutoresizingMaskIntoConstraints = false

        addSubview(caption); addSubview(input)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: Self.height),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.centerYAnchor.constraint(equalTo: centerYAnchor),
            caption.widthAnchor.constraint(equalToConstant: 74),
            input.leadingAnchor.constraint(equalTo: caption.trailingAnchor, constant: 8),
            input.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // A path is chosen, not spelled. Typing one is possible and it is the
        // fallback, not the affordance: the field truncates from the HEAD so a
        // long path shows the part that identifies it, and the button opens the
        // picker that already knows what a folder is.
        if browsable {
            let browse = ConsoleButton(title: "", target: self, action: #selector(browseTapped))
            browse.isBordered = false
            // Not a bottom-line door — it lives in the settings pane and keeps
            // its own letterspaced sans, so it re-inks through the generic hook.
            browse.reink = { [weak browse] color in
                browse?.attributedTitle = letterspaced(
                    "CHOOSE…", size: 9.5, tracking: 1.33, color: color)
            }
            browse.restingInk = StateLegend.Palette.accent
            browse.translatesAutoresizingMaskIntoConstraints = false
            addSubview(browse)
            NSLayoutConstraint.activate([
                browse.trailingAnchor.constraint(equalTo: trailingAnchor),
                browse.centerYAnchor.constraint(equalTo: centerYAnchor),
                input.trailingAnchor.constraint(equalTo: browse.leadingAnchor, constant: -10),
            ])
        } else {
            input.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ value: String) { input.stringValue = value }

    @objc private func browseTapped() { onBrowse?() }

    func controlTextDidEndEditing(_ obj: Notification) { onCommit?(input.stringValue) }
}

/// The settings pane's tabs.
///
/// Restored from the design (docs/settings-recent.html v3,
/// docs/settings-microphone.html v1), which drew Settings as a tab bar from the
/// start. The build had drifted into one scrolling column with a
/// "Recent audio ▸" link buried among the voices, and then grew launch settings
/// on top of that — three unrelated concerns in one list, which is how a pane
/// stops being navigable.
///
/// Only the tabs with panes behind them are here. The design also names
/// Microphone, Permissions and Keys; those are proposals, and a tab that opens
/// an empty pane is worse than a tab that is not there yet.
enum SettingsTab: String, CaseIterable {
    case agents = "AGENTS"
    case voices = "VOICES"
    case recent = "RECENT"
}

/// A row of tabs: the current one in ink, the rest in hint, a hairline beneath.
///
/// Not NSSegmentedControl — its bezel is the same AppKit chrome the rest of
/// this panel refuses, and on a dark console it reads as a foreign object. Caps
/// are the instrument voice, so tabs wear them: these are controls, not prose.
final class SettingsTabBar: NSView {
    static let height: CGFloat = 30
    private var buttons: [SettingsTab: NSButton] = [:]
    private let rule = NSView()
    var onSelect: ((SettingsTab) -> Void)?
    private(set) var selected: SettingsTab = .agents

    init(width: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        rule.wantsLayer = true
        rule.layer?.backgroundColor = StateLegend.Palette.hairline.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)

        var previous: NSView?
        for tab in SettingsTab.allCases {
            // A ConsoleButton for the cursor alone: no `restingInk`, because
            // a tab's ink already carries which one is open and hover must not
            // overwrite a louder signal with a quieter one.
            let button = ConsoleButton(title: "", target: self, action: #selector(tapped(_:)))
            button.isBordered = false
            button.identifier = NSUserInterfaceItemIdentifier(tab.rawValue)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            buttons[tab] = button
            NSLayoutConstraint.activate([
                button.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),
                button.leadingAnchor.constraint(
                    equalTo: previous?.trailingAnchor ?? leadingAnchor,
                    constant: previous == nil ? 0 : 18),
            ])
            previous = button
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: Self.height),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.widthAnchor.constraint(equalToConstant: width),
            rule.heightAnchor.constraint(equalToConstant: 1),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func select(_ tab: SettingsTab) {
        selected = tab
        paint()
    }

    private func paint() {
        for (tab, button) in buttons {
            let lit = tab == selected
            button.attributedTitle = letterspaced(
                tab.rawValue, size: 9.5, tracking: 1.33,
                color: lit ? StateLegend.Palette.ink : StateLegend.Palette.hint)
        }
    }

    @objc private func tapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let tab = SettingsTab(rawValue: raw) else { return }
        select(tab)
        onSelect?(tab)
    }
}
