import AppKit
import TranquilityCore

/// Project folders on the real panel (ruled 29 Sep 2026,
/// `docs/rulings/ruling-project-folders.md`). Core's tests hold the layout
/// rules; this holds what only a panel can show: that the headers and indents
/// are drawn in that order, that a collapsed header wears the lamp, that a
/// drag's hold makes a folder, that rename takes the keyboard and gives it
/// back, and that a held grid does not repaint under the pointer.
///
/// Runs against a scratch store, never the user's `projects.json`, and never
/// asks the model for a name. The drag is driven through the panel's own
/// entry points with an NSEvent object, never posted to the system: synthetic
/// input on a live machine has ended a real dictation before.
extension StatusHUD {

    func projectFoldersDrill() {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-folders-drill-\(UUID().uuidString)", isDirectory: true)
        let store = ProjectStore(url: scratch.appendingPathComponent("projects.json"))
        let realStore = projects
        let modelWas = nameFoldersWithModel
        projects = store
        nameFoldersWithModel = false
        defer {
            projects = realStore
            nameFoldersWithModel = modelWas
            rowsHeld = false
            gridDrag?.ghost.removeFromSuperview()
            gridDrag = nil
            undoDrop = nil
            namingFolders = []
            try? FileManager.default.removeItem(at: scratch)
        }

        func row(_ id: String, _ lamp: Lamp, _ at: TimeInterval, _ name: String? = nil) -> SessionRow {
            SessionRow(id: id, name: name ?? id, aux: id, lamp: lamp,
                       read: lamp == .ready ? .unread : .none, hasRecordedTurn: true,
                       lastActivity: Date(timeIntervalSince1970: at))
        }
        let rows = SessionRow.quietRowsLast([
            row("m1", .ready, 100), row("m2", .working, 300), row("t1", .working, 50),
            row("l1", .ready, 200, "Kopi hero defects"), row("l2", .working, 250, "Kopi calendar fill"),
        ])
        // The user's order puts TB first. TB is only working and Mirai asks,
        // and TB stays first all the same: folder order is sticky (rule 3,
        // re-ruled 29 Sep).
        store.update {
            $0.create(name: "TB", with: ["t1"], id: "tb")
            $0.create(name: "Mirai", with: ["m1", "m2"], id: "mirai")
            $0.create(name: "Kopi", with: ["k1"], id: "kopi")
        }
        showIdle(rows: rows)

        func drawn() -> [String] {
            gridLines.map { entry in
                switch entry.line {
                case let .header(folder, _, _, _): return "[\(folder.name)]"
                case let .row(row, folder):
                    let indented = entry.view is FolderMemberView
                    return (folder != nil && indented ? "  " : "") + row.id
                }
            }
        }
        let firstPaint = drawn()
        let foldersKeepTheUsersOrder = firstPaint == ["[TB]", "  t1", "[Mirai]", "  m1", "  m2", "l1", "l2"]
        let hideAndWait = !firstPaint.contains("[Kopi]") && store.current.folder(id: "kopi") != nil
        let menusSurviveIndent = Dictionary(uniqueKeysWithValues: gridRowsForTesting)["m1"] != nil

        // Rules inside a folder start at the indent, one above each of its
        // rows; nothing else draws inside a folder.
        let rules = waitingRows.arrangedSubviews.filter {
            $0.identifier?.rawValue == "folder-rule"
                && $0.subviews.first?.frame.minX == FolderHeaderView.indent
        }.count
        let folderRulesIndented = rules == 3   // Mirai: header|m1|m2, TB: header|t1

        // Collapse and reopen: the panel comes back to the height it had, so
        // no row is pushed out of sight.
        let openHeight = intendedHeight ?? 0
        toggleFolder("mirai")
        let shutHeight = intendedHeight ?? 0
        toggleFolder("mirai")
        let reopenRefits = panel?.isVisible != true
            || (shutHeight < openHeight && abs((intendedHeight ?? 0) - openHeight) < 0.5)

        // A folder dropped on the lower half of another folder's ROWS lands
        // below it, not only on its 28pt header.
        var folderDropsOnRows = false
        if let header = header(for: "tb"),
           let member = gridLines.first(where: { $0.line.row?.id == "m2" })?.view,
           let window = header.window {
            let low = member.convert(NSPoint(x: member.bounds.midX, y: member.bounds.minY + 3), to: nil)
            let start = header.convert(NSPoint(x: header.bounds.midX, y: header.bounds.midY), to: nil)
            if let down = NSEvent.mouseEvent(with: .leftMouseDragged, location: start, modifierFlags: [],
                                             timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1),
               let over = NSEvent.mouseEvent(with: .leftMouseDragged, location: low, modifierFlags: [],
                                             timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) {
                dragged(.folder("tb"), view: header, phase: .began, event: down)
                dragged(.folder("tb"), view: header, phase: .moved, event: over)
                let aimed = gridDrag?.target == .reorder(folder: "mirai", after: true)
                    && gridDrag?.bar?.isHidden == false
                dragged(.folder("tb"), view: header, phase: .ended, event: over)
                // And it stays there although TB's agent is not the one asking.
                folderDropsOnRows = aimed
                    && Array(drawn().compactMap { $0.hasPrefix("[") ? $0 : nil }.prefix(2)) == ["[Mirai]", "[TB]"]
            }
        }

        // Collapse: one header, the lamp, the count; its row gone from view.
        toggleFolder("tb")
        let tb = header(for: "tb")
        let collapsedShowsLampAndCount = tb?.lampForTesting == Lamp.working.fill.cgColor
            && tb?.countForTesting == "1" && !drawn().contains("  t1")
        toggleFolder("tb")

        // A held grid does not repaint under the pointer, and pays the debt on release.
        let beforeHold = drawn()
        rowsHeld = true
        showIdle(rows: rows.filter { $0.id != "m2" })
        let heldDidNotRepaint = drawn() == beforeHold && rowsDirty
        rowsHeld = false
        rebuildSessionRows()
        let releaseRepaints = !drawn().contains("  m2") && !rowsDirty
        showIdle(rows: rows)

        // A drag whose mouse-up never came (the panel hid mid-drag) must not
        // freeze the grid: with the button up, the next repaint lets go.
        rowsHeld = true
        gridDrag = GridDrag(source: .row("l1"), ghost: NSImageView(), grab: .zero)
        showIdle(rows: rows.filter { $0.id != "m2" })
        let abandonedDragLetsGo = NSEvent.pressedMouseButtons & 1 != 0
            || (!rowsHeld && gridDrag == nil && !drawn().contains("  m2"))
        showIdle(rows: rows)

        // The drag: l1 rests on the middle of l2, the hold elapses, the drop
        // makes a folder named by the fallback (no model in a drill).
        var dragMadeFolder = false
        var wholeRowIsTheTarget = false
        var ghostDoesNotSnap = false
        var dropDidNotOpenACard = false
        if let source = gridLines.first(where: { $0.line.row?.id == "l1" })?.view,
           let target = gridLines.first(where: { $0.line.row?.id == "l2" })?.view,
           let window = source.window {
            let middle = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType, _ at: NSPoint) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil,
                                   eventNumber: 0, clickCount: 1, pressure: 1)
            }
            let start = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
            if let down = event(.leftMouseDragged, start), let over = event(.leftMouseDragged, middle) {
                rowDragged("l1", from: source, phase: .began, event: down)
                rowDragged("l1", from: source, phase: .moved, event: over)
                let notYet = gridDrag?.target == nil
                gridDrag?.resting?.since = Date().addingTimeInterval(-1)
                rowDragged("l1", from: source, phase: .moved, event: over)
                let armed = gridDrag?.target == .makeFolder(with: "l2")
                // Armed stays armed anywhere on the row, and the ghost stays
                // where the pointer is when the hold's timer re-asks.
                let nearEdge = target.convert(NSPoint(x: target.bounds.minX + 12,
                                                      y: target.bounds.minY + 5), to: nil)
                var stillArmed = false
                var ghostStays = false
                if let edge = event(.leftMouseDragged, nearEdge) {
                    rowDragged("l1", from: source, phase: .moved, event: edge)
                    let before = gridDrag?.ghost.frame.origin
                    retarget()
                    stillArmed = gridDrag?.target == .makeFolder(with: "l2")
                    ghostStays = gridDrag?.ghost.frame.origin == before
                    rowDragged("l1", from: source, phase: .moved, event: over)
                }
                wholeRowIsTheTarget = stillArmed
                ghostDoesNotSnap = ghostStays
                let stateBefore = state
                rowDragged("l1", from: source, phase: .ended, event: over)
                let made = store.current.folder(of: "l1")
                dragMadeFolder = notYet && armed && made != nil
                    && made?.id == store.current.folder(of: "l2")?.id && made?.name == "Kopi"
                dropDidNotOpenACard = state == stateBefore
            }
        }
        // The undo is the top band's one receipt, never a row that pushes the
        // grid down.
        let undoInTheTopBand = (panel?.isVisible != true
                                || receiptChip?.stringValue.hasSuffix("· UNDO") == true)
            && !waitingRows.arrangedSubviews.contains { $0.identifier?.rawValue == "folder-undo" }

        // Dragging the last agents out closes the folder.
        if let made = store.current.folder(of: "l1")?.id {
            apply(.leave, to: "l1")
            apply(.leave, to: "l2")
            _ = made
        }
        let lastOutClosesIt = store.current.folders.map(\.name) == ["Mirai", "TB", "Kopi"]

        // Rename: the keyboard is taken, the grid held, and both given back.
        var renameTakesAndReturnsKeys = false
        if let mirai = header(for: "mirai") {
            mirai.beginRename()
            let took = panel?.acceptsKey == true && rowsHeld && mirai.editorForTesting != nil
            mirai.editorForTesting?.stringValue = "Mirai BFCM"
            mirai.finishRename(keep: true)
            renameTakesAndReturnsKeys = took && panel?.acceptsKey == false && !rowsHeld
                && store.current.folder(id: "mirai")?.name == "Mirai BFCM"
                && store.current.names.contains("Mirai BFCM")
        }

        // A revived agent lands back in its waiting folder.
        showIdle(rows: SessionRow.quietRowsLast(rows + [row("k1", .ready, 400)]))
        let painted = drawn()
        let reviveGoesHome = painted.firstIndex(of: "[Kopi]").map {
            $0 + 1 < painted.count && painted[$0 + 1] == "  k1" } ?? false

        // Past Agents stays flat and wears the chip.
        let chipped = PastRowView(item: .init(row: row("p1", .unlit, 1), revivable: true,
                                              haystack: "p1 Mirai", folder: "Mirai"),
                                  target: self, action: #selector(backTapped))
        let plain = PastRowView(item: .init(row: row("p2", .unlit, 1), revivable: true, haystack: "p2"),
                                target: self, action: #selector(backTapped))
        let pastWearsTheChip = chipped.chipForTesting == "MIRAI" && plain.chipForTesting == nil

        SelfTest.report("projectFolders", [
            ("foldersKeepTheUsersOrder", foldersKeepTheUsersOrder),
            ("hideAndWait", hideAndWait),
            ("menusSurviveIndent", menusSurviveIndent),
            ("collapsedShowsLampAndCount", collapsedShowsLampAndCount),
            ("heldDidNotRepaint", heldDidNotRepaint),
            ("releaseRepaints", releaseRepaints),
            ("abandonedDragLetsGo", abandonedDragLetsGo),
            ("dragMadeFolder", dragMadeFolder),
            ("dropDidNotOpenACard", dropDidNotOpenACard),
            ("undoInTheTopBand", undoInTheTopBand),
            ("wholeRowIsTheTarget", wholeRowIsTheTarget),
            ("folderRulesIndented", folderRulesIndented),
            ("reopenRefits", reopenRefits),
            ("folderDropsOnRows", folderDropsOnRows),
            ("ghostDoesNotSnap", ghostDoesNotSnap),
            ("lastOutClosesIt", lastOutClosesIt),
            ("renameTakesAndReturnsKeys", renameTakesAndReturnsKeys),
            ("reviveGoesHome", reviveGoesHome),
            ("pastWearsTheChip", pastWearsTheChip),
        ])
        Permissions.log("projectFolders drill: first paint \(firstPaint)")
        showIdle(rows: [])
    }

    /// Poses for `--pose-shot`: the grid with folders, a collapsed one, and a
    /// drag resting on a loose row. A scratch store, so a photograph never
    /// writes the user's folders; the process exits after the shot.
    func poseFolders(_ name: String) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-folders-pose-\(UUID().uuidString)", isDirectory: true)
        projects = ProjectStore(url: scratch.appendingPathComponent("projects.json"))
        nameFoldersWithModel = false
        func row(_ id: String, _ name: String, _ lamp: Lamp, _ at: TimeInterval) -> SessionRow {
            SessionRow(id: id, name: name, aux: String(id.prefix(8)), lamp: lamp,
                       read: lamp == .ready ? .unread : .none, hasRecordedTurn: true,
                       lastActivity: Date(timeIntervalSince1970: at))
        }
        let rows = SessionRow.quietRowsLast([
            row("98bcd108", "Mirai flows for BFCM", .ready, 90),
            row("60b5dccf", "Mirai email revenue analysis", .working, 80),
            row("01a0a09c", "Klaviyo segment audit", .ready, 40),
            row("b0b3646b", "Tranquility-base audio clarity", .ready, 70),
            row("441562dc", "Agent grouping and project folders", .working, 95),
            row("40b13260", "Missing Agent card on click", .working, 60),
            row("3295857f", "Arkady Media Agency ROI", .fault, 50),
            row("ee3ef1b7", "U Vape newsletter drafts", .working, 30),
            row("5c0ffee1", "U Vape checkout flow", .ready, 20),
            row("747e1cam", "747 El Camino lease notice", .ready, 10),
        ])
        projects.update {
            $0.create(name: "Tranquility Base", with: ["b0b3646b", "441562dc", "40b13260"], id: "tb")
            $0.create(name: "Mirai", with: ["98bcd108", "60b5dccf", "01a0a09c"], id: "mirai")
            if name == "folders-collapsed" { $0.setCollapsed("tb", true) }
        }
        showIdle(rows: rows)
        guard name == "folders-drag" || name == "folders-undo",
              let source = gridLines.first(where: { $0.line.row?.id == "ee3ef1b7" })?.view,
              let target = gridLines.first(where: { $0.line.row?.id == "5c0ffee1" })?.view,
              let window = source.window else { return }
        let start = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
        let over = target.convert(NSPoint(x: target.bounds.midX + 40, y: target.bounds.midY + 6), to: nil)
        guard let down = NSEvent.mouseEvent(with: .leftMouseDragged, location: start, modifierFlags: [],
                                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1),
              let move = NSEvent.mouseEvent(with: .leftMouseDragged, location: over, modifierFlags: [],
                                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        rowDragged("ee3ef1b7", from: source, phase: .began, event: down)
        rowDragged("ee3ef1b7", from: source, phase: .moved, event: move)
        gridDrag?.resting?.since = Date().addingTimeInterval(-1)
        rowDragged("ee3ef1b7", from: source, phase: .moved, event: move)
        if name == "folders-undo" {
            rowDragged("ee3ef1b7", from: source, phase: .ended, event: move)
        }
    }
}
