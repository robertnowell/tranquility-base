import AppKit
import TranquilityCore

/// Explicit native acceptance. No applicationDidFinishLaunching, microphone,
/// updater, ownership lock, credential copying, or production app replacement.
@MainActor
enum SavedAccountsLiveDrill {
    struct Failure: Error { let message: String }

    static func run() async -> Bool {
        let env = ProcessInfo.processInfo.environment
        let support = QueueStore.supportDirectory.resolvingSymlinksInPath()
        guard env["VOICE_DISPATCH_SUPPORT_DIR"] != nil,
              ["/private/tmp/tb-account-app-drill-", "/tmp/tb-account-app-drill-"].contains(where: support.path.hasPrefix),
              let target = env["TB_ACCOUNT_DRILL_TARGET"],
              let account = SavedAccountStore.shared.account(target),
              let directory = env["TB_ACCOUNT_DRILL_PROJECT"],
              URL(fileURLWithPath: directory).resolvingSymlinksInPath().path.hasPrefix(support.deletingLastPathComponent().path + "/"),
              env["CLAUDE_CONFIG_DIR"] == nil else {
            print("FAIL explicit isolated support, project and saved target are required")
            print("support=\(support.path), project=\(env["TB_ACCOUNT_DRILL_PROJECT"] ?? "missing"), saved=\(SavedAccountStore.shared.all().count), configUnset=\(env["CLAUDE_CONFIG_DIR"] == nil)")
            return false
        }
        let delegate = AppDelegate()
        delegate.speakLaunchGreeting = { _, _ in }
        var panes: [TmuxPaneAddress] = []
        defer {
            // Only panes this drill launched on its private server are eligible.
            for pane in panes { Tmux.run(["kill-session", "-t", pane.sessionName], socket: pane.socketName) }
            if let records = try? LaunchRecoveryStore.shared.records() {
                for record in records where record.directory == directory {
                    if let name = record.paneSession { Tmux.run(["kill-session", "-t", name], socket: Tmux.socketName) }
                }
            }
            try? SavedAccountStore.shared.save(account)
            delegate.hud.hide()
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(message: message) }
            print("PASS \(message)")
        }
        func wait(_ condition: @MainActor () throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(65)
            while Date() < deadline {
                if try condition() { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw Failure(message: "Timed out waiting for the real app path")
        }
        do {
            let store = try QueueStore()
            delegate.store = store
            delegate.coordinator = Coordinator(store: store, attachments: .persistent())
            delegate.wireSavedAccountActions()
            let sourcePane = try await Task.detached {
                try SessionLauncher.launch(directory: directory,
                                           launch: HarnessLaunch(harness: ClaudeCodeAdapter().id)).get()
            }.value
            panes.append(sourcePane)
            let sourceID = await Task.detached {
                LaunchGreeting.awaitRegistration(directory: directory, excluding: [], matches: {
                    $0.registryTmux?.hasPrefix(sourcePane.sessionName + ":") == true
                        && $0.registryTmux?.hasSuffix("." + sourcePane.paneId) == true
                })
            }.value
            guard let sourceID else { throw Failure(message: "Main did not register") }
            _ = try LaunchGreeting.record(sessionId: sourceID, directory: directory, line: "Acceptance source", store: store)

            func send(_ session: String, text: String, expectsPointer: String? = nil) async throws {
                guard let coordinator = delegate.coordinator else { throw Failure(message: "Missing coordinator") }
                let reply = try await coordinator.submitTypedReply(text: text, to: session)
                guard case .readyToSend(let utterance, let outgoing, _, let actual) = reply else {
                    throw Failure(message: "Typed reply was not prepared")
                }
                try require(actual == session, "prepared reply keeps its selected session")
                if let expectsPointer {
                    try require(outgoing.contains(expectsPointer) && outgoing.contains(text), "handoff pointer and typed instruction travel together")
                }
                let outcome = try await coordinator.confirmAndSend(utteranceId: utterance)
                guard case .dispatched = outcome else { throw Failure(message: "Native dispatch was not confirmed: \(outcome)") }
                try require(coordinator.attachments.staged(for: session).isEmpty, "confirmed delivery clears only its destination draft")
                print("PASS native transcript confirms delivery to \(session)")
            }
            try await send(sourceID, text: "Reply exactly TB_APP_SOURCE. Do not use tools.")
            var previous = sourceID
            var secondID: String?
            for destination in [target, ClaudeCodeAdapter().id] {
                let known = Set(try LaunchRecoveryStore.shared.records().map(\.id))
                delegate.hud.onContinueWork?(previous, "Acceptance source", destination)
                var bound: LaunchRecoveryRecord?
                try await wait {
                    bound = try LaunchRecoveryStore.shared.records().first {
                        !known.contains($0.id) && $0.targetID == destination && $0.state == "bound"
                    }
                    guard let id = bound?.sessionID else { return false }
                    let recorded = try store.allKnownSessions().contains { $0.sessionId == id }
                    return delegate.activeConversation?.sessionId == id && recorded
                }
                guard let id = bound?.sessionID else { throw Failure(message: "Missing destination") }
                try require(id != previous, "Continue creates a fresh destination conversation")
                try require(SessionAccountStore.shared.binding(id)?.targetID == destination, "destination binds to the chosen saved account")
                let persisted = AttachmentStore.persistent()
                try require(persisted.staged(for: id).contains { $0.contains(previous) }, "pointer draft survives reopening its store")
                delegate.coordinator = Coordinator(store: store, attachments: persisted)
                if let content = delegate.hud.panel?.contentView,
                   let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: support.appendingPathComponent("handoff-\(destination).png"))
                }
                try await send(id, text: "ACCEPTANCE ONLY: Reply exactly TB_APP_HANDOFF. Do not use tools or read other files.", expectsPointer: previous)
                if destination == target { secondID = id }
                previous = id
            }
            // Refuse an identity mismatch before any destination process exists.
            var mismatched = account
            mismatched.email = "wrong-identity@acceptance.invalid"
            try SavedAccountStore.shared.save(mismatched)
            let known = Set(try LaunchRecoveryStore.shared.records().map(\.id))
            delegate.hud.onContinueWork?(secondID!, "Acceptance recovery", target)
            var unresolved: LaunchRecoveryRecord?
            try await wait {
                unresolved = try LaunchRecoveryStore.shared.records().first {
                    !known.contains($0.id) && $0.state == "unresolved"
                }
                return unresolved != nil
            }
            guard let unresolved, let coordinator = delegate.coordinator else { throw Failure(message: "Missing recovery receipt") }
            _ = try await coordinator.submitTypedReply(text: "KEEP_THIS_FAILED_LAUNCH_INSTRUCTION", to: unresolved.id)
            try require(unresolved.paneID == nil, "identity mismatch refuses process creation")
            try require(AttachmentStore.persistent().staged(for: unresolved.id).contains { $0.contains(secondID!) }, "failed launch preserves its source pointer on disk")
            try require(try LaunchRecoveryStore.shared.records().first { $0.id == unresolved.id }?.instruction == "KEEP_THIS_FAILED_LAUNCH_INSTRUCTION", "failed launch preserves its typed instruction on disk")
            let successful = try LaunchRecoveryStore.shared.records().filter { $0.sessionID != nil }
            try require(successful.allSatisfy { $0.state == "bound" }, "later launches preserve completed handoff receipts")
            print("Saved accounts live app: PASS")
            return true
        } catch {
            print("Saved accounts live app: FAIL \(error)")
            return false
        }
    }
}
