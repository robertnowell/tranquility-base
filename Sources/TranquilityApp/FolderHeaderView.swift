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
    /// Drawn, not typed: a "›" or "⌄" glyph sits on the text baseline, so it
    /// rode low beside the capitals (29 Sep, "alignment weird with the
    /// chevrons, not centered in text"). A stroked path centred on the
    /// capitals' own middle sits where the eye expects it.
    private let chevron = ChevronView()
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

        chevron.pointsDown = !folder.collapsed
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
            chevron.widthAnchor.constraint(equalToConstant: ChevronView.size),
            chevron.heightAnchor.constraint(equalToConstant: ChevronView.size),
            // The middle of the capitals: half a cap height above the baseline.
            chevron.centerYAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor,
                                             constant: -StateLegend.Face.chrome(10).capHeight / 2),
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

/// A row inside a folder: indented, and that is all. There was a vertical
/// guide line down the left; where it met the rules between rows it made box
/// corners and left stubs, and it read as a bracket drawn around the folder
/// rather than as grouping (29 Sep, "these lines are a little jank", then
/// "lines still a bit weird"). The indent, and rules that start at it, carry
/// the grouping on their own, as a sidebar's nested items do.
final class FolderMemberView: NSView {
    let row: GridRowView
    let folderId: String

    init(row: GridRowView, folderId: String, width: CGFloat) {
        self.row = row
        self.folderId = folderId
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: GridRowView.height),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FolderHeaderView.indent),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The rule above a folder's row: it starts where the row's lamp starts,
    /// so the folder's rows sit in their own column. The rule that closes a
    /// folder is the grid's ordinary full-width one.
    static func rule(width: CGFloat) -> NSView {
        let rule = NSView()
        rule.identifier = NSUserInterfaceItemIdentifier("folder-rule")
        rule.translatesAutoresizingMaskIntoConstraints = false
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = StateLegend.Palette.hairlineSoft.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        rule.addSubview(line)
        NSLayoutConstraint.activate([
            rule.widthAnchor.constraint(equalToConstant: width),
            rule.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: rule.leadingAnchor, constant: FolderHeaderView.indent),
            line.trailingAnchor.constraint(equalTo: rule.trailingAnchor),
            line.topAnchor.constraint(equalTo: rule.topAnchor),
            line.bottomAnchor.constraint(equalTo: rule.bottomAnchor),
        ])
        return rule
    }
}

/// The folder's disclosure mark: a small open chevron, pointing down when the
/// folder is open and right when it is closed, stroked in the strip's hint ink.
final class ChevronView: NSView {
    static let size: CGFloat = 9
    var pointsDown = true { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        let s = Self.size, arm: CGFloat = 2.5
        let mid = NSPoint(x: s / 2, y: s / 2)
        if pointsDown {
            path.move(to: NSPoint(x: mid.x - arm * 1.3, y: mid.y - arm * 0.65))
            path.line(to: NSPoint(x: mid.x, y: mid.y + arm * 0.65))
            path.line(to: NSPoint(x: mid.x + arm * 1.3, y: mid.y - arm * 0.65))
        } else {
            path.move(to: NSPoint(x: mid.x - arm * 0.65, y: mid.y - arm * 1.3))
            path.line(to: NSPoint(x: mid.x + arm * 0.65, y: mid.y))
            path.line(to: NSPoint(x: mid.x - arm * 0.65, y: mid.y + arm * 1.3))
        }
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        StateLegend.Palette.hint.setStroke()
        path.stroke()
    }
}
