import AppKit
import TranquilityCore

/// The app's half of agent names (11 Nov 2026): the wiring for the grid's
/// Rename, and the name a continued agent is given at its first message.
extension AppDelegate {

    func wireAgentNames() {
        // What an agent is working toward, for the folder namer. A database
        // read, and the namer calls it from its own detached task.
        let queue = store
        hud.goalForNaming = { id in (try? queue?.carriedGoal(for: id)) ?? nil }
        // A rename repaints the grid from the store rather than patching the
        // row, so what is shown is what every surface will resolve.
        hud.onAgentRenamed = { [weak self] _ in
            guard let self, case .idle = self.hud.state else { return }
            self.showIdleGrid()
        }
        // Single writer, set once here: see `Coordinator.onContinuationSent`.
        Coordinator.onContinuationSent = { [weak self] sessionId, continuation in
            Task { @MainActor in self?.nameContinuedAgent(sessionId, continuation) }
        }
    }

    /// An agent started with "Continue work with" has just received its
    /// first message. Give it a name of its own.
    ///
    /// Its harness will title it from that same message, which opens with
    /// the source's name in quotes: measured over 45 days, 7 of 17 continued
    /// agents came back with a title identical or nearly identical to their
    /// source's, and no title changed afterwards. So the name is chosen here,
    /// from the instruction the user gave AFTER the handoff, and stored where
    /// it outranks the harness's title.
    ///
    /// Once per agent: a name already given, by the user or by an earlier
    /// call, is left alone.
    func nameContinuedAgent(_ sessionId: String, _ continuation: AgentHandoff.Continuation,
                            names: AgentNameStore = .shared, useModel: Bool = true) {
        let origin = SessionLineage.lastKnownOrigin
        guard names.current.entry(for: sessionId, origin: origin) == nil else { return }
        let taken = hud.namesOnTheGrid + names.current.names.values.map(\.name)
        let fallback = AgentNamer.fallback(sourceName: continuation.sourceName, taken: taken)
        let instruction = continuation.instruction

        func give(_ name: String, by how: String) {
            let took = names.update { $0.give(name, to: sessionId, source: .auto, origin: origin) }
            Permissions.log("names: continued agent \(sessionId.prefix(8)) named by \(how)"
                + (took ? "" : " (not taken: the user had named it)"))
            Track.record("agent_named", ["agent_id": Track.hash(sessionId), "by": .token(how)])
            if case .idle = hud.state { showIdleGrid() }
        }

        // Nothing to name it by: the handoff was sent alone. The number is
        // the honest name, and it is given now so the row never wears its
        // source's.
        guard useModel, !instruction.isEmpty else {
            give(fallback, by: instruction.isEmpty ? "number" : "number_no_model")
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            var proposed: String?
            let openRouter = OpenRouterSummaryProvider(timeout: 6)
            let anthropic = AnthropicSummaryProvider(timeout: 6)
            if openRouter.isConfigured || anthropic.isConfigured {
                let system = AgentNamer.system
                let user = AgentNamer.prompt(sourceName: continuation.sourceName,
                                             instruction: instruction, taken: taken)
                let reply = openRouter.isConfigured
                    ? try? await openRouter.complete(system: system, user: user)
                    : try? await anthropic.complete(system: system, user: user)
                proposed = reply.flatMap {
                    AgentNamer.clean($0.text, taken: taken + [continuation.sourceName])
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // The user may have renamed it while the model was thinking.
                guard names.current.entry(for: sessionId, origin: origin) == nil else { return }
                if let proposed { give(proposed, by: "model") } else { give(fallback, by: "number") }
            }
        }
    }
}
