import AppKit
import TranquilityCore

/// Renaming an agent from the grid (11 Nov 2026).
///
/// Robert: *"I need to be able to rename an agent from the grid. If I
/// right-click and hit rename, I need to be able to rename it in a way that
/// doesn't mess up anything. You know, ending, restarting."*
///
/// The name goes into `AgentNameStore`, this app's own file, keyed by the
/// conversation's origin id. Nothing is typed into the agent and nothing is
/// written to its transcript, so there is nothing for an end, a revive or a
/// relaunch to undo: `GridAssembler` asks the store first every time it
/// names a session, on the grid, on the card and on the hub alike.
extension StatusHUD {

    /// Every agent row on the grid, whether loose or inside a folder.
    var shownGridRowViews: [GridRowView] {
        waitingRows.arrangedSubviews.compactMap {
            ($0 as? GridRowView) ?? ($0 as? FolderMemberView)?.row
        }
    }

    func gridRowView(for id: String) -> GridRowView? {
        shownGridRowViews.first { $0.identifier?.rawValue == id }
    }

    @objc nonisolated func renameAgentPicked(_ sender: NSMenuItem) {
        // The id is lifted out before the hop, like every other row item.
        let picked = sender.representedObject as? String
        MainActor.assumeIsolated {
            guard let id = picked else { return }
            Track.record("row_menu", ["item": "rename", "agent_id": Track.hash(id), "surface": "grid"])
            beginAgentRename(id)
        }
    }

    func beginAgentRename(_ id: String) {
        guard let row = gridRowView(for: id) else { return }
        row.onRenameBegan = { [weak self] in self?.beginFolderRename() }
        row.onRenameEnded = { [weak self] name in self?.endAgentRename(id, name: name) }
        row.beginRename()
    }

    /// nil: cancelled. Empty: back to the automatic name. Otherwise the name.
    func endAgentRename(_ id: String, name: String?) {
        if let name {
            let origin = SessionLineage.lastKnownOrigin
            if name.isEmpty {
                agentNames.update { $0.clear(id, origin: origin) }
                Track.record("agent_renamed", ["agent_id": Track.hash(id), "to": "automatic"])
            } else {
                agentNames.update { _ = $0.give(name, to: id, source: .user, origin: origin) }
                Track.record("agent_renamed", ["agent_id": Track.hash(id), "to": "typed"])
            }
            Permissions.log("names: \(id.prefix(8)) "
                + (name.isEmpty ? "given back its automatic name" : "renamed by hand"))
        }
        releaseKeyboard()
        rowsHeld = false
        // The rows are rebuilt from the store, not patched here: the name a
        // person sees after a rename is the one every other surface resolves.
        if name != nil { onAgentRenamed?(id) }
        refitGrid()
    }

    /// The names on the grid now, for a namer that must not repeat one.
    var namesOnTheGrid: [String] { face.sessionRows.map(\.name) }

    // MARK: - The drill

    /// What only a panel can show: that the row menu's Rename opens an editor
    /// on that row, takes the keyboard and gives it back, writes the store,
    /// that Escape changes nothing, that clearing the field gives the
    /// automatic name back, and that a row inside a folder renames too.
    ///
    /// Against a scratch store, never the user's `agent-names.json`. Driven
    /// through the menu item's own target and action, never a posted event.
    /// The folder half of a continuation's first message: the new agent
    /// joins its source's folder. Returns the folder joined, or nil when the
    /// source is loose or the user already filed the new agent.
    @discardableResult
    func fileContinuedAgent(_ sessionId: String,
                            _ continuation: AgentHandoff.Continuation) -> String? {
        let origin = SessionLineage.lastKnownOrigin
        return projects.update {
            $0.follow(sessionId, source: continuation.sourceSessionId, origin: origin)
        }
    }

    func agentNamesDrill() {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-agent-names-drill-\(UUID().uuidString)", isDirectory: true)
        let names = AgentNameStore(url: scratch.appendingPathComponent("agent-names.json"))
        let folders = ProjectStore(url: scratch.appendingPathComponent("projects.json"))
        let realNames = agentNames, realFolders = projects, realRenamed = onAgentRenamed
        let priorDestinations = handoffDestinations
        agentNames = names
        projects = folders
        handoffDestinations = { [] }
        var renamedIds: [String] = []
        onAgentRenamed = { renamedIds.append($0) }
        defer {
            agentNames = realNames
            projects = realFolders
            onAgentRenamed = realRenamed
            handoffDestinations = priorDestinations
            rowsHeld = false
            try? FileManager.default.removeItem(at: scratch)
            showIdle(rows: [])
        }

        func row(_ id: String, _ name: String) -> SessionRow {
            SessionRow(id: id, name: name, aux: SessionRow.shortId(id), lamp: .working,
                       read: .none, hasRecordedTurn: true, lastActivity: Date())
        }
        folders.update { $0.create(name: "Mirai", with: ["drill-names-c"], id: "mirai") }
        showIdle(rows: [row("drill-names-a", "YouVape email flows"),
                        row("drill-names-b", "YouVape email flows"),
                        row("drill-names-c", "Mirai hero CTA font color")])

        func pickRename(_ id: String) -> Bool {
            guard let item = gridRowView(for: id)?.menu?.items.first(where: { $0.title == "Rename" })
            else { return false }
            _ = item.target?.perform(item.action, with: item)
            return true
        }

        // Return keeps: the store has it, the row wears it, the keys go back.
        let offered = pickRename("drill-names-b")
        let editing = gridRowView(for: "drill-names-b")
        let took = panel?.acceptsKey == true && rowsHeld && editing?.editorForTesting != nil
        let opensOnTheCurrentName = editing?.editorForTesting?.stringValue == "YouVape email flows"
        editing?.editorForTesting?.stringValue = "  YouVape flow revenue\n"
        editing?.finishRename(keep: true)
        let kept = names.current.entry(for: "drill-names-b")
            == .init(name: "YouVape flow revenue", source: .user)
        let gaveBack = panel?.acceptsKey == false && !rowsHeld
        let rowWearsIt = editing?.nameLabel.stringValue == "YouVape flow revenue"

        // Escape changes nothing.
        _ = pickRename("drill-names-a")
        let escaping = gridRowView(for: "drill-names-a")
        escaping?.editorForTesting?.stringValue = "Thrown away"
        escaping?.finishRename(keep: false)
        let escapeKeepsTheOldName = names.current.entry(for: "drill-names-a") == nil
            && panel?.acceptsKey == false && !rowsHeld

        // A row inside a folder renames the same way.
        let inFolderOffered = pickRename("drill-names-c")
        let member = gridRowView(for: "drill-names-c")
        member?.editorForTesting?.stringValue = "Mirai button colour"
        member?.finishRename(keep: true)
        let folderMemberRenames = names.current.name(for: "drill-names-c") == "Mirai button colour"
            && folders.current.folder(of: "drill-names-c")?.id == "mirai"

        // An automatic name does not replace the typed one, and clearing the
        // field hands the name back to the harness.
        let autoRefused = names.update { $0.give("The model's idea", to: "drill-names-b", source: .auto) } == false
        _ = pickRename("drill-names-b")
        let clearing = gridRowView(for: "drill-names-b")
        clearing?.editorForTesting?.stringValue = "   "
        clearing?.finishRename(keep: true)
        let clearingGivesTheAutomaticNameBack = names.current.entry(for: "drill-names-b") == nil

        // A continued agent joins its source's folder, read from the real
        // handoff message. A loose source leaves it loose, and one the user
        // already filed is not moved.
        func handoff(from id: String, _ name: String) -> AgentHandoff.Continuation? {
            AgentHandoff.continuation(in: AgentHandoff.fragment(
                sourceName: name, sourceHarness: "claude", sourceSessionId: id,
                logLocation: "/dev/null", reportsDirectory: nil) + "\n\nFix the footer too")
        }
        let fromFolder = handoff(from: "drill-names-c", "Mirai button colour")
        let joined = fromFolder.flatMap { fileContinuedAgent("drill-names-d", $0) }
        showIdle(rows: [row("drill-names-a", "YouVape email flows"),
                        row("drill-names-c", "Mirai button colour"),
                        row("drill-names-d", "Mirai footer")])
        let cloneJoinsTheFolder = joined == "mirai"
            && folders.current.memberCount(of: "mirai") == 2
            && gridRowView(for: "drill-names-d") != nil
        let fromLoose = handoff(from: "drill-names-a", "YouVape email flows")
        let looseSourceLeavesItLoose = fromLoose != nil
            && fromLoose.flatMap { fileContinuedAgent("drill-names-e", $0) } == nil
            && folders.current.folder(of: "drill-names-e") == nil
        folders.update { $0.create(name: "Kopi", with: ["drill-names-f"], id: "kopi") }
        let filedCloneIsNotMoved = fromFolder.flatMap { fileContinuedAgent("drill-names-f", $0) } == nil
            && folders.current.folder(of: "drill-names-f")?.id == "kopi"

        // And it survives the process: a second store on the same file.
        let survivesARelaunch = AgentNameStore(url: names.url).current.name(for: "drill-names-c")
            == "Mirai button colour"

        SelfTest.report("agent-names", [
            ("renameIsOnTheRowMenu", offered),
            ("itOpensOnTheCurrentName", opensOnTheCurrentName),
            ("itTakesTheKeyboardAndHoldsTheGrid", took),
            ("returnKeepsTheName", kept),
            ("theRowWearsItAtOnce", rowWearsIt),
            ("theKeyboardAndTheGridAreGivenBack", gaveBack),
            ("theAppIsToldToRebuildTheRows", renamedIds == ["drill-names-b", "drill-names-c", "drill-names-b"]),
            ("escapeKeepsTheOldName", escapeKeepsTheOldName),
            ("aRowInAFolderRenamesAndStaysInIt", inFolderOffered && folderMemberRenames),
            ("anAutomaticNameNeverReplacesATypedOne", autoRefused),
            ("clearingGivesTheAutomaticNameBack", clearingGivesTheAutomaticNameBack),
            ("theNameSurvivesARelaunch", survivesARelaunch),
            ("aContinuedAgentJoinsItsSourcesFolder", cloneJoinsTheFolder),
            ("aLooseSourceLeavesItLoose", looseSourceLeavesItLoose),
            ("aCloneTheUserFiledIsNotMoved", filedCloneIsNotMoved),
        ])
    }
}
