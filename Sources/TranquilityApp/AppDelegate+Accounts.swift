import AppKit
import TranquilityCore

extension AppDelegate {
    func wireSavedAccountActions() {
        hud.onNewSession = { [weak self] in self?.newSession() }
        hud.onNewAccountSession = { [weak self] id in self?.newSession(targetID: id) }
        hud.onManageAccounts = { [weak self] in self?.manageSavedAccounts() }
        hud.onRecoverLaunches = { [weak self] in self?.recoverSavedLaunches() }
        hud.onContinueWork = { [weak self] id, name, harness in
            self?.continueWork(from: id, name: name, to: harness)
        }
        // Every ready agent whose start can carry the fragment. crobot begins
        // on its own compose page, which takes a repository and not words, so
        // the handoff would arrive empty; it is not offered.
        hud.handoffDestinations = { [weak self] in
            AgentHandoff.destinations(ready: StatusHUD.agentTiles()) { harness in
                guard let provider = self?.providerRegistry?.provider(harness) else { return true }
                return provider.composeURL(for: Brief(prompt: "")) == nil
            }
        }
    }

    @objc func manageSavedAccounts() {
        let alert = NSAlert()
        alert.messageText = "Saved accounts"
        alert.informativeText = "Each account keeps its own sign-in. Both use your existing projects and knowledge base."
        alert.addButton(withTitle: "Add account…")
        alert.addButton(withTitle: "Import profile…")
        let existing = SavedAccountStore.shared.all()
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        if !existing.isEmpty {
            picker.addItems(withTitles: existing.map { $0.label + ($0.email.map { " · " + $0 } ?? "") })
            alert.accessoryView = picker
            alert.addButton(withTitle: "Reconnect selected…")
        }
        alert.addButton(withTitle: "Done")
        let response = alert.runModal()
        if !existing.isEmpty, response == .alertThirdButtonReturn {
            let selected = existing[picker.indexOfSelectedItem]
            // Reconnect retains the pinned identity. A different login needs its own entry.
            openShell(selected.scopedCommand("claude auth login --claudeai"), in: AgentDefaults.directory(for: selected.id))
            return
        }
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
        let name = NSAlert()
        name.messageText = "Name this account"
        name.informativeText = "This name appears in New agent and Continue work with."
        let input = NSTextField(string: "")
        input.placeholderString = "Work or Personal"
        input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        name.accessoryView = input
        name.addButton(withTitle: "Continue"); name.addButton(withTitle: "Cancel")
        guard name.runModal() == .alertFirstButtonReturn else { return }
        let label = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { hud.showResult("Enter an account name."); return }
        let id = UUID().uuidString.lowercased()
        let root: URL
        if response == .alertSecondButtonReturn {
            let picker = NSOpenPanel()
            picker.message = "Choose the existing account’s configuration folder."
            picker.canChooseFiles = false; picker.canChooseDirectories = true
            picker.showsHiddenFiles = true; picker.allowsMultipleSelection = false
            guard picker.runModal() == .OK, let selected = picker.url else { return }
            root = selected
        } else {
            root = QueueStore.supportDirectory.appendingPathComponent("agent-profiles").appendingPathComponent(id)
        }
        let importing = response == .alertSecondButtonReturn
        let account = SavedAccount(id: id, label: label, configDirectory: root.path)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                var account = account
                if importing {
                    let identity = try SavedAccountIdentity.read(account: account)
                    account.email = identity.email; account.organization = identity.organization
                } else {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                           attributes: [.posixPermissions: 0o700])
                }
                try SavedAccountStore.shared.save(account)
                try account.installIntegration()
                ClaudeAgentsCLI.invalidate()
                let saved = account
                await MainActor.run {
                    guard let self else { return }
                    if importing {
                        self.hud.showResult("Saved \(saved.label). Choose it from New agent or Continue work with.")
                    } else {
                        self.openShell(saved.scopedCommand("claude auth login --claudeai"), in: AgentDefaults.directory(for: saved.id))
                        self.hud.showResult("Finish signing into \(saved.label) in the opened terminal. Then choose it from New agent.")
                    }
                }
            } catch {
                await MainActor.run { self?.hud.showResult(error.localizedDescription) }
            }
        }
    }

    @objc func recoverSavedLaunches() {
        let attachments = coordinator?.attachments
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let records = try LaunchRecoveryStore.shared.records().filter { $0.state != "bound" && $0.state != "discarded" }
                ClaudeAgentsCLI.invalidate()
                let sessions = ClaudeAgentsCLI().sessions() ?? []
                for record in records {
                    let matches = sessions.filter { LaunchRecoveryStore.matches($0, record: record) }
                    guard matches.count == 1, let session = matches.first else { continue }
                    attachments?.adopt(stagingKey: record.id, asSession: session.sessionId)
                    // A previously typed instruction is restored as a draft, never auto-sent.
                    if let instruction = record.instruction, !instruction.isEmpty {
                        attachments?.stage(instruction, session: session.sessionId)
                    }
                    guard attachments?.persistenceError == nil else {
                        throw AccountConfigurationError.invalid("Could not save the recovered draft.")
                    }
                    try LaunchRecoveryStore.shared.update(record.id) { $0.sessionID = session.sessionId; $0.state = "bound" }
                    await MainActor.run {
                        guard let self else { return }
                        if let store = self.store {
                            _ = try? LaunchGreeting.record(sessionId: session.sessionId, directory: record.directory,
                                                          line: "Your pending draft is ready.", voice: nil, store: store)
                        }
                        self.activeConversation = (session.sessionId, (record.directory as NSString).lastPathComponent, record.directory)
                        self.refreshDropTarget()
                        self.hud.showResult("Recovered your draft. Review it before sending.")
                    }
                    return
                }
                await MainActor.run {
                    guard self != nil else { return }
                    let alert = NSAlert()
                    alert.messageText = "Pending launch recovery"
                    alert.informativeText = records.isEmpty
                        ? "No unbound launches were found. Saved delivery receipts remain available for inspection."
                        : "The original session could not be identified yet. Your drafts are retained. No new session was started and nothing was resent."
                    alert.addButton(withTitle: "Show saved recovery files")
                    if !records.isEmpty { alert.addButton(withTitle: "Discard all \(records.count) pending drafts") }
                    alert.addButton(withTitle: "Done")
                    let action = alert.runModal()
                    if action == .alertFirstButtonReturn {
                        NSWorkspace.shared.activateFileViewerSelecting([LaunchRecoveryStore.shared.fileURL])
                    } else if !records.isEmpty, action == .alertSecondButtonReturn {
                        Task.detached {
                            for record in records {
                                attachments?.clearStaged(session: record.id)
                                guard attachments?.persistenceError == nil else { return }
                                try? LaunchRecoveryStore.shared.update(record.id) { $0.state = "discarded"; $0.instruction = nil }
                            }
                        }
                    }
                }
            } catch { await MainActor.run { self?.hud.showResult(error.localizedDescription) } }
        }
    }
}
