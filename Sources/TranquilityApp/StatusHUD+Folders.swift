import AppKit
import TranquilityCore

/// Project folders on the grid: headers, the drag that makes and fills them,
/// renaming in place, and the name the model proposes. Ruled 29 Sep 2026,
/// `docs/rulings/ruling-project-folders.md`; the layout rules themselves are
/// Core's (`ProjectLayout`), where tests can hold them.
///
/// The drag is tracked inside the panel from the row's own mouse events, not
/// through the system drag session: the panel's background already accepts
/// file drops (`DropSurfaceView`), and a row is not a file. Rows are never
/// reordered by hand, since the grid computes the order, so a drop means one
/// of three things only: onto the middle of a loose row (held a moment) makes
/// a folder, anywhere on a folder joins it, the loose rows leave it.

/// The drag in flight.
struct GridDrag {
    enum Source: Equatable { case row(String), folder(String) }
    enum Target: Equatable {
        case makeFolder(with: String)
        case join(folder: String)
        case leave
        case reorder(folder: String, after: Bool)
    }
    let source: Source
    let ghost: NSImageView
    let grab: NSPoint
    /// What a release would do right now.
    var target: Target?
    /// The loose row the pointer is resting on, before the hold makes it a
    /// folder target.
    var resting: (id: String, since: Date)?
    /// Where the pointer last was, in window coordinates. The hold's timer
    /// re-asks the target from HERE, never from the point it was armed at:
    /// re-asking from a stale point snapped the ghost back and flickered the
    /// outline (reported 29 Sep, "the drag folder on top kind of snaps
    /// around ... the outlines flash in and out").
    var lastPoint: NSPoint = .zero
    /// The line that says where a dragged folder will land.
    var bar: NSView?
}

extension StatusHUD {

    /// How long the pointer rests on a loose row before a drop there makes a
    /// folder. Short enough to feel immediate, long enough that sweeping past
    /// a row on the way to somewhere else does not group it (Discord's folder
    /// gesture has the same guard; Android's launcher uses a radius instead).
    static let folderHold: TimeInterval = 0.25

    // MARK: - Drawing

    func folderHeader(_ folder: ProjectBook.Folder, lamp: Lamp?, lit: Int,
                      members: Int) -> FolderHeaderView {
        let header = FolderHeaderView(folder: folder, lamp: lamp, lit: lit, members: members,
                                      naming: namingFolders.contains(folder.id),
                                      width: Self.gridWidth)
        header.onToggle = { [weak self] in self?.toggleFolder(folder.id) }
        header.onRenameBegan = { [weak self] in self?.beginFolderRename() }
        header.onRenameEnded = { [weak self] name in self?.endFolderRename(folder.id, name: name) }
        header.onDrag = { [weak self, weak header] phase, event in
            guard let self, let header else { return }
            self.dragged(.folder(folder.id), view: header, phase: phase, event: event)
        }
        header.menu = folderMenu(folder)
        return header
    }

    // MARK: - Collapse, menus

    func toggleFolder(_ folderId: String) {
        let collapsed = !(projects.current.folder(id: folderId)?.collapsed ?? false)
        projects.update { $0.setCollapsed(folderId, collapsed) }
        Track.record("folder_toggled", ["collapsed": .token(collapsed ? "yes" : "no")])
        refitGrid()
    }

    private func folderMenu(_ folder: ProjectBook.Folder) -> NSMenu {
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename", action: #selector(renameFolderPicked(_:)),
                                keyEquivalent: "")
        rename.target = self
        rename.representedObject = folder.id
        menu.addItem(rename)
        menu.addItem(.separator())
        let delete = NSMenuItem(title: "Delete folder \u{201C}\(folder.name)\u{201D}",
                                action: #selector(deleteFolderPicked(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = folder.id
        menu.addItem(delete)
        return menu
    }

    @objc nonisolated func renameFolderPicked(_ sender: NSMenuItem) {
        let picked = sender.representedObject as? String
        MainActor.assumeIsolated {
            guard let id = picked else { return }
            header(for: id)?.beginRename()
        }
    }

    @objc nonisolated func deleteFolderPicked(_ sender: NSMenuItem) {
        let picked = sender.representedObject as? String
        MainActor.assumeIsolated {
            guard let id = picked, let folder = projects.current.folder(id: id) else { return }
            let before = projects.current
            projects.update { $0.delete(id) }
            noteDrop("Deleted \(folder.name.uppercased())", before: before)
            Track.record("folder_deleted", [:])
            refitGrid()
        }
    }

    @objc nonisolated func removeFromFolderPicked(_ sender: NSMenuItem) {
        let picked = sender.representedObject as? String
        MainActor.assumeIsolated {
            guard let id = picked else { return }
            apply(.leave, to: id)
        }
    }

    @objc nonisolated func undoDropTapped() {
        MainActor.assumeIsolated {
            guard let undo = undoDrop, undo.until > Date(), receiptIsShowing else { return }
            projects.restore(undo.before)
            undoDrop = nil
            clearReceipt()
            Track.record("folder_undo", [:])
            refitGrid()
        }
    }

    func header(for folderId: String) -> FolderHeaderView? {
        gridLines.lazy.compactMap { $0.view as? FolderHeaderView }.first { $0.folderId == folderId }
    }

    /// Say what the drop did in the top band's receipt chip, which a click
    /// undoes. Undo lives exactly as long as the chip's own linger (4 s for a
    /// landed receipt): once the notice has gone, so has the way back.
    private func noteDrop(_ text: String, before: ProjectBook) {
        undoDrop = (text, before, Date().addingTimeInterval(4))
        showReceipt(.folderChange(text))
    }

    /// Repaint the rows and fit the panel to them. A folder change alters
    /// the grid's height, and repainting the rows alone left the panel at its
    /// old size: reopening a folder pushed the bottom rows out of sight
    /// (29 Sep, "you lose the bottom rows, because it repaints on collapse
    /// but not uncollapse").
    func refitGrid() {
        rebuildSessionRows()
        guard !rowsHeld, let panel, panel.isVisible else { return }
        resizeToFit(panel)
        position(panel)
    }

    // MARK: - A hold nobody is holding

    /// A held grid whose gesture ended without telling us: the button is up
    /// with a drag still recorded (the panel hid mid-drag, the mouse-up went
    /// to another window), or a rename left open for two minutes. Without
    /// this the grid would stop repainting for good.
    func heldGridIsStale() -> Bool {
        if gridDrag != nil { return NSEvent.pressedMouseButtons & 1 == 0 }
        return Date().timeIntervalSince(rowsHeldSince) > 120
    }

    func releaseHeldGrid(because reason: String) {
        gridDrag?.ghost.removeFromSuperview()
        gridDrag?.bar?.removeFromSuperview()
        gridDrag = nil
        for header in gridLines.compactMap({ $0.view as? FolderHeaderView })
        where header.editorForTesting != nil {
            header.finishRename(keep: false)
        }
        rowsHeld = false
        Permissions.log("folders: released a held grid, \(reason)")
    }

    // MARK: - Drag

    func rowDragged(_ id: String, from view: NSView, phase: GridDragPhase, event: NSEvent) {
        dragged(.row(id), view: view, phase: phase, event: event)
    }

    func dragged(_ source: GridDrag.Source, view: NSView, phase: GridDragPhase, event: NSEvent) {
        switch phase {
        case .began: beginDrag(source, view: view, event: event)
        case .moved: moveDrag(to: event.locationInWindow)
        case .ended: endDrag()
        }
    }

    func beginDrag(_ source: GridDrag.Source, view: NSView, event: NSEvent) {
        guard gridDrag == nil, let content = panel?.contentView else { return }
        rowsHeld = true
        let image = NSImage(size: view.bounds.size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            image.addRepresentation(rep)
        }
        let ghost = NSImageView(image: image)
        ghost.wantsLayer = true
        ghost.alphaValue = 0.85
        ghost.layer?.backgroundColor = StateLegend.Palette.surface.cgColor
        ghost.layer?.cornerRadius = 4
        ghost.layer?.shadowOpacity = 0.4
        ghost.layer?.shadowRadius = 8
        let origin = content.convert(view.bounds.origin, from: view)
        ghost.frame = NSRect(origin: origin, size: view.bounds.size)
        content.addSubview(ghost)
        view.alphaValue = 0.3
        let grab = content.convert(event.locationInWindow, from: nil)
        gridDrag = GridDrag(source: source, ghost: ghost,
                            grab: NSPoint(x: grab.x - origin.x, y: grab.y - origin.y))
        if case .row = source {
            Track.record("folder_drag", ["what": .token("row")])
        } else {
            Track.record("folder_drag", ["what": .token("folder")])
        }
        moveDrag(to: event.locationInWindow)
    }

    func moveDrag(to windowPoint: NSPoint) {
        guard var drag = gridDrag, let content = panel?.contentView else { return }
        let point = content.convert(windowPoint, from: nil)
        drag.ghost.setFrameOrigin(NSPoint(x: point.x - drag.grab.x, y: point.y - drag.grab.y))
        drag.lastPoint = windowPoint
        gridDrag = drag
        retarget()
    }

    /// Ask what a release would do at the pointer's latest point, and repaint
    /// the feedback only if the answer changed. Called on every move and once
    /// by the hold's timer; never moves the ghost.
    func retarget() {
        guard var drag = gridDrag else { return }
        let (target, resting) = dropTarget(drag, at: drag.lastPoint)
        if let resting {
            if drag.resting?.id != resting { drag.resting = (resting, Date()) }
        } else {
            drag.resting = nil
        }
        let changed = drag.target != target
        drag.target = target
        gridDrag = drag
        if changed { paintDropTarget(drag) }
        // The hold: once it elapses, resting still is enough to arm the row.
        if let resting = drag.resting, target != .makeFolder(with: resting.id) {
            let since = resting.since
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.folderHold + 0.02) { [weak self] in
                guard let self, let now = self.gridDrag, now.resting?.id == resting.id,
                      now.resting?.since == since else { return }
                self.retarget()
            }
        }
    }

    /// What a release at this point would do, and the loose row being rested on.
    func dropTarget(_ drag: GridDrag, at windowPoint: NSPoint) -> (GridDrag.Target?, String?) {
        let book = projects.current
        let origin = SessionLineage.lastKnownOrigin
        let under = gridLines.first { entry in
            entry.view.convert(entry.view.bounds, to: nil).contains(windowPoint)
        }
        switch drag.source {
        case let .folder(moving):
            // The whole folder is the target, header and rows alike: its top
            // half puts the dragged folder above it, its bottom half below.
            // It was the 28pt header only (29 Sep, "I wanna drag folders above
            // and below other folders easily"). Below every folder, on the
            // loose rows, it goes last.
            let owner: String?
            switch under?.line {
            case let .header(folder, _, _, _)?: owner = folder.id
            case let .row(_, folder?)?: owner = folder
            default: owner = nil
            }
            if let owner, owner != moving, let block = folderBlock(owner) {
                return (.reorder(folder: owner, after: windowPoint.y < block.midY), nil)
            }
            if owner == nil, under?.line.row != nil,
               let last = gridLines.compactMap({ $0.line.folder?.id }).last(where: { $0 != moving }) {
                return (.reorder(folder: last, after: true), nil)
            }
            return (nil, nil)

        case let .row(id):
            let current = book.folder(of: id, origin: origin)?.id
            switch under?.line {
            case let .header(folder, _, _, _)?:
                return (folder.id == current ? nil : .join(folder: folder.id), nil)
            case let .row(_, folder?)?:
                return (folder == current ? nil : .join(folder: folder), nil)
            case let .row(row, nil)?:
                guard row.id != id else {
                    return (current == nil ? nil : .leave, nil)
                }
                // The whole row is the target, and the HOLD is what tells a
                // folder from a pass-through: a row armed once stays armed
                // while the pointer is anywhere on it. It was the middle half
                // only, which made you aim for the dead centre and dropped the
                // outline every time the pointer strayed a few points
                // (reported 29 Sep, "I have to be directly over the center").
                let held = drag.resting?.id == row.id
                    && Date().timeIntervalSince(drag.resting!.since) >= Self.folderHold
                if held { return (.makeFolder(with: row.id), row.id) }
                return (current == nil ? nil : .leave, row.id)
            case nil:
                // Anywhere else on the grid below the folders is the loose rows.
                let stack = waitingRows.convert(waitingRows.bounds, to: nil)
                return (current != nil && stack.contains(windowPoint) ? .leave : nil, nil)
            }
        }
    }

    /// The folder's header and rows as one rectangle, in window coordinates.
    func folderBlock(_ folderId: String) -> NSRect? {
        let views = gridLines.filter { entry in
            switch entry.line {
            case let .header(folder, _, _, _): return folder.id == folderId
            case let .row(_, folder): return folder == folderId
            }
        }.map { $0.view.convert($0.view.bounds, to: nil) }
        guard let first = views.first else { return nil }
        return views.dropFirst().reduce(first) { $0.union($1) }
    }

    private func showInsertionBar(folder: String, after: Bool) {
        guard let content = panel?.contentView, let block = folderBlock(folder) else { return }
        let bar = gridDrag?.bar ?? {
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.backgroundColor = StateLegend.Palette.ready.cgColor
            bar.layer?.cornerRadius = 1
            content.addSubview(bar, positioned: .below, relativeTo: gridDrag?.ghost)
            gridDrag?.bar = bar
            return bar
        }()
        let edge = content.convert(NSRect(x: block.minX, y: after ? block.minY : block.maxY,
                                          width: block.width, height: 0), from: nil)
        bar.frame = NSRect(x: edge.minX, y: edge.minY - 1, width: edge.width, height: 2)
        bar.isHidden = false
    }

    private func paintDropTarget(_ drag: GridDrag) {
        drag.bar?.isHidden = true
        for entry in gridLines {
            (entry.view as? FolderHeaderView)?.setDropTarget(false)
            (entry.view as? FolderHeaderView)?.setInsertion(nil)
            if let row = entry.view as? GridRowView { row.layer?.borderWidth = 0 }
        }
        switch drag.target {
        case let .join(folder)?:
            header(for: folder)?.setDropTarget(true)
        case let .reorder(folder, after)?:
            showInsertionBar(folder: folder, after: after)
        case let .makeFolder(with)?:
            if let row = gridLines.first(where: { $0.line.row?.id == with })?.view as? GridRowView {
                row.layer?.borderWidth = 1.5
                row.layer?.borderColor = StateLegend.Palette.ready.cgColor
                row.layer?.cornerRadius = 6
            }
        case .leave?, nil:
            break
        }
    }

    func endDrag() {
        guard let drag = gridDrag else { return }
        gridDrag = nil
        drag.ghost.removeFromSuperview()
        drag.bar?.removeFromSuperview()
        rowsHeld = false
        switch (drag.source, drag.target) {
        case let (.row(id), target?):
            apply(target, to: id)
        case let (.folder(id), .reorder(target, after)?):
            let before = projects.current
            projects.update { $0.move(id, to: target, after: after) }
            noteDrop("Moved \(projects.current.folder(id: id)?.name.uppercased() ?? "folder")",
                     before: before)
            refitGrid()
        default:
            refitGrid()
        }
    }

    /// A drop, whether from the pointer, the row menu or a drill.
    func apply(_ target: GridDrag.Target, to id: String) {
        let origin = SessionLineage.lastKnownOrigin
        let before = projects.current
        switch target {
        case let .makeFolder(with):
            let agents = [id, with].map(namingAgent)
            let name = ProjectNamer.fallback(agents)
            let folder = projects.update { $0.create(name: name, with: [with, id], origin: origin) }
            namingFolders.insert(folder)
            noteDrop("Made a folder", before: before)
            Track.record("folder_made", [:])
            nameFolder(folder, agents: agents)
        case let .join(folder):
            projects.update { $0.join(id, folder: folder, origin: origin) }
            noteDrop("Moved to \(projects.current.folder(id: folder)?.name.uppercased() ?? "folder")",
                     before: before)
            Track.record("folder_joined", [:])
        case .leave:
            let gone = projects.update { $0.leave(id, origin: origin) }
            noteDrop(gone == nil ? "Moved out" : "Folder \(gone!.name.uppercased()) closed",
                     before: before)
            Track.record("folder_left", ["closed": .token(gone == nil ? "no" : "yes")])
        case .reorder:
            break
        }
        refitGrid()
    }

    // MARK: - Naming

    private func namingAgent(_ id: String) -> ProjectNamer.Agent {
        let title = face.sessionRows.first { $0.id == id }?.name ?? SessionRow.shortId(id)
        let cwd = SessionDiscovery.discoverIfScanned()?.sessions
            .first { $0.sessionId == id }?.cwd
        return .init(title: title, folder: cwd.map { ($0 as NSString).lastPathComponent })
    }

    /// Ask the model for a name, off the main actor. The fallback is already
    /// on the header, so a slow, missing or useless answer changes nothing
    /// but the shimmer.
    func nameFolder(_ folderId: String, agents: [ProjectNamer.Agent]) {
        let vocabulary = projects.current.names
        let store = projects
        let useModel = nameFoldersWithModel
        Task.detached(priority: .utility) {
            var proposed: String?
            let provider = AnthropicSummaryProvider(timeout: 6)
            if useModel, provider.isConfigured {
                let reply = try? await provider.complete(
                    system: ProjectNamer.system,
                    user: ProjectNamer.prompt(agents, vocabulary: vocabulary))
                proposed = reply.flatMap { ProjectNamer.clean($0.text) }
            }
            await MainActor.run { [weak self] in
                // The user may have renamed it, or deleted it, while we waited.
                if let proposed, store.current.folder(id: folderId) != nil,
                   self?.namingFolders.contains(folderId) == true {
                    store.update { $0.rename(folderId, to: proposed) }
                }
                self?.namingFolders.remove(folderId)
                Permissions.log("folder: named \(folderId) \(proposed == nil ? "by fallback" : "by model")")
                self?.refitGrid()
            }
        }
    }

    // MARK: - Rename

    func beginFolderRename() {
        rowsHeld = true
        guard let panel else { return }
        panel.acceptsKey = true
        panel.makeKeyAndOrderFront(nil)
    }

    func endFolderRename(_ folderId: String, name: String?) {
        if let name {
            namingFolders.remove(folderId)
            projects.update { $0.rename(folderId, to: name) }
            Track.record("folder_renamed", [:])
        }
        releaseKeyboard()
        rowsHeld = false
        refitGrid()
    }
}
