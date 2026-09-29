import AppKit
import TranquilityCore

/// A project folder's header on the grid (ruled 29 Sep 2026,
/// `docs/rulings/ruling-project-folders.md`).
///
/// Shorter than a row and in the grid's own chrome: the tracked capitals the
/// AGENTS strip wears, a chevron, and, when collapsed, the most urgent lamp of
/// its members with a count. It reads as grouping, not as another row.
///
/// Gestures: a click on the chevron collapses; a double-click on the name
/// renames; a drag reorders folders. All three are reported to the panel,
/// which owns the store.
final class FolderHeaderView: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 28
    /// How far a folder's rows sit in from the loose ones.
    static let indent: CGFloat = 14

    let folderId: String
    private let chevron = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let lamp = NSView()
    private var editor: NSTextField?
    private var downAt: NSPoint?
    private var dragging = false

    var onToggle: (() -> Void)?
    var onRenameBegan: (() -> Void)?
    /// The new name, or nil when the edit was cancelled.
    var onRenameEnded: ((String?) -> Void)?
    var onDrag: ((GridDragPhase, NSEvent) -> Void)?

    init(folder: ProjectBook.Folder, lamp aggregate: Lamp?, lit: Int, members: Int,
         naming: Bool, width: CGFloat) {
        folderId = folder.id
        super.init(frame: .zero)
        currentName = folder.name
        identifier = NSUserInterfaceItemIdentifier("folder:\(folder.id)")
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 4

        chevron.attributedStringValue = Widgets.letterspaced(
            folder.collapsed ? "›" : "⌄", size: 11, tracking: 0, color: StateLegend.Palette.hint)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        let title = naming ? "NAMING…" : folder.name.uppercased()
        nameLabel.attributedStringValue = Widgets.letterspaced(
            title, size: 10, tracking: 3.2,
            color: naming ? StateLegend.Palette.hint : StateLegend.Palette.secondary)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Rule 4: a collapsed folder wears its most urgent member's lamp and
        // the number lit. An open one wears nothing; its rows speak.
        let showsState = folder.collapsed
        countLabel.font = GridRowView.auxFont
        countLabel.textColor = StateLegend.Palette.muted
        countLabel.alignment = .right
        countLabel.stringValue = showsState ? "\(aggregate == nil ? members : lit)" : ""
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        lamp.translatesAutoresizingMaskIntoConstraints = false
        lamp.wantsLayer = true
        lamp.layer?.cornerRadius = Lamp.diameter / 2
        lamp.layer?.backgroundColor = (aggregate?.fill ?? .clear).cgColor
        lamp.isHidden = !showsState || aggregate == nil

        for view in [chevron, nameLabel, countLabel, lamp] { addSubview(view) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: Self.height),
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GridRowView.lampColumn),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: lamp.leadingAnchor, constant: -10),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            lamp.widthAnchor.constraint(equalToConstant: Lamp.diameter),
            lamp.heightAnchor.constraint(equalToConstant: Lamp.diameter),
            lamp.centerYAnchor.constraint(equalTo: centerYAnchor),
            lamp.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -6),
        ])
        toolTip = folder.collapsed
            ? "\(folder.name): \(members) agent\(members == 1 ? "" : "s"). Click › to open."
            : "\(folder.name). Double-click to rename, drag to move."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var nameForTesting: String { nameLabel.stringValue }
    var lampForTesting: CGColor? { lamp.isHidden ? nil : lamp.layer?.backgroundColor }
    var countForTesting: String { countLabel.stringValue }

    /// Drop feedback: the whole folder is the target.
    func setDropTarget(_ on: Bool) {
        layer?.backgroundColor = on ? StateLegend.Palette.ready.withAlphaComponent(0.16).cgColor : nil
    }

    /// Header-on-header: a line above or below says where it will land.
    func setInsertion(_ edge: NSRectEdge?) {
        layer?.borderWidth = 0
        layer?.shadowOpacity = 0
        guard let edge else { return }
        layer?.masksToBounds = false
        layer?.shadowColor = StateLegend.Palette.ready.cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 0
        layer?.shadowOffset = CGSize(width: 0, height: edge == .maxY ? 2 : -2)
    }

    // MARK: - Pointer

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        dragging = false
        if event.clickCount == 2, editor == nil {
            beginRename()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard editor == nil, let downAt else { return }
        let here = event.locationInWindow
        if !dragging, hypot(here.x - downAt.x, here.y - downAt.y) >= 4 {
            dragging = true
            onDrag?(.began, event)
        }
        if dragging { onDrag?(.moved, event) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil; dragging = false }
        if dragging { onDrag?(.ended, event); return }
        guard event.clickCount == 1, editor == nil else { return }
        // A single click anywhere but the name collapses; on the name it waits
        // to see whether a second click makes it a rename.
        let point = convert(event.locationInWindow, from: nil)
        if point.x < GridRowView.lampColumn || !nameLabel.frame.contains(point) { onToggle?() }
    }

    // MARK: - Rename in place

    func beginRename() {
        let field = NSTextField(string: nameLabel.stringValue == "NAMING…" ? "" : currentName)
        field.font = StateLegend.Face.chrome(11)
        field.textColor = StateLegend.Palette.ink
        field.backgroundColor = StateLegend.Palette.surface
        field.drawsBackground = true
        field.isBordered = true
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.cell?.isScrollable = true
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor, constant: -3),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        nameLabel.isHidden = true
        editor = field
        onRenameBegan?()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// The folder's name as the user typed it, not the capitals it wears.
    var currentName = ""

    func controlTextDidEndEditing(_ note: Notification) { finishRename(keep: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            finishRename(keep: false)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            finishRename(keep: true)
            return true
        }
        return false
    }

    /// Driven directly by the drill; the same path Enter and Escape take.
    func finishRename(keep: Bool) {
        guard let field = editor else { return }
        editor = nil
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        field.removeFromSuperview()
        nameLabel.isHidden = false
        onRenameEnded?(keep && !typed.isEmpty ? typed : nil)
    }

    var editorForTesting: NSTextField? { editor }
}

/// What a drag on the grid reports to the panel.
enum GridDragPhase { case began, moved, ended }

/// A row inside a folder: indented, with one hairline down its left to say
/// which folder holds it.
final class FolderMemberView: NSView {
    let row: GridRowView
    let folderId: String

    init(row: GridRowView, folderId: String, width: CGFloat) {
        self.row = row
        self.folderId = folderId
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let guide = NSView()
        guide.wantsLayer = true
        guide.layer?.backgroundColor = StateLegend.Palette.hairline.cgColor
        guide.translatesAutoresizingMaskIntoConstraints = false
        addSubview(guide)
        addSubview(row)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: GridRowView.height),
            guide.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.guideX),
            guide.widthAnchor.constraint(equalToConstant: 1),
            guide.topAnchor.constraint(equalTo: topAnchor),
            guide.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FolderHeaderView.indent),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The x of the guide line, shared by the rows and the rules between them.
    static let guideX: CGFloat = 4

    /// The rule between two rows of one folder: it starts at the guide and
    /// lights the guide's pixel, so the guide never breaks at a row boundary.
    static func rule(width: CGFloat) -> NSView {
        let rule = NSView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = StateLegend.Palette.hairlineSoft.cgColor
        let guide = NSView()
        guide.wantsLayer = true
        guide.layer?.backgroundColor = StateLegend.Palette.hairline.cgColor
        for view in [line, guide] {
            view.translatesAutoresizingMaskIntoConstraints = false
            rule.addSubview(view)
        }
        NSLayoutConstraint.activate([
            rule.widthAnchor.constraint(equalToConstant: width),
            rule.heightAnchor.constraint(equalToConstant: 1),
            guide.leadingAnchor.constraint(equalTo: rule.leadingAnchor, constant: guideX),
            guide.widthAnchor.constraint(equalToConstant: 1),
            guide.topAnchor.constraint(equalTo: rule.topAnchor),
            guide.bottomAnchor.constraint(equalTo: rule.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: guide.trailingAnchor),
            line.trailingAnchor.constraint(equalTo: rule.trailingAnchor),
            line.topAnchor.constraint(equalTo: rule.topAnchor),
            line.bottomAnchor.constraint(equalTo: rule.bottomAnchor),
        ])
        return rule
    }
}
