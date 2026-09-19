import AppKit
import TranquilityCore

/// The app's half of the hands-free manager (19 Sep 2026).
///
/// The manager is a stdio child that listens all day and drives the fleet
/// through the doors the app already has. This file holds the one thing it
/// cannot do from outside: speak a line in a SESSION's own voice, with the
/// panel in sync. `rung` and `say` deep links land here. Nothing in it records,
/// sends, or types; it is the ⌃⌃ ladder's speaking half, reached by URL.
extension AppDelegate {

    /// A session id, or the unique session the prefix names. The manager
    /// reads ids from JSON and often keeps only the first eight characters.
    func resolveSession(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw.count >= 32 { return raw }
        return (try? store?.sessionId(matching: raw)) ?? raw
    }

    /// Speak `spoken` as the session would. With the manager on, the orb stays
    /// on the grid and the line under it says who is speaking; the card is for
    /// hands. Otherwise the same sequence the ladder uses: stop what is
    /// playing, supersede any armed announcement, show the card, speak.
    @MainActor
    func speakForManager(session: String, spoken: SanitizedSpokenText, placard: String) {
        guard let coordinator else { return }
        Permissions.log("manager: speaking \(placard) for \(session.prefix(8)): \(spoken.text.prefix(200))")
        if managerIsOn {
            returnToGridWork?.cancel()
            let previous = announceTask
            announceTask = Task { @MainActor in
                coordinator.speech.stop()
                previous?.cancel()
                _ = await previous?.value
                guard !Task.isCancelled else { return }
                let goal = (try? store.flatMap { try ManagerJSON.brief(store: $0, sessionId: session) })??.goal
                hud.setManagerState(StatusHUD.orbState, line: goal ?? "the session is speaking", mood: "speaking")
                let voices = coordinator.voices(for: session)
                _ = await coordinator.speech.speak(
                    spoken, voice: voices.cloud, systemVoice: voices.system, onWord: { _ in })
                hud.setManagerState(StatusHUD.orbState, line: "listening")
            }
            return
        }
        returnToGridWork?.cancel()
        let previous = announceTask
        announceTask = Task { @MainActor in
            coordinator.speech.stop()
            previous?.cancel()
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            let event = try? store?.latestStop(for: session)
            let live = ((ClaudeAgentsCLI().sessions() ?? [])
                + FileSessionOwnershipStore.shared.liveNonRegistrySessions())
                .first { $0.sessionId == session }
            hud.showAnnouncement(
                spoken: spoken,
                sessionId: session,
                pid: live?.pid,
                project: event.map { tabDisplayName(for: $0, live: live) }
                    ?? (live?.cwd as NSString?)?.lastPathComponent ?? "",
                cwd: event?.cwd ?? live?.cwd,
                eventId: session,
                placard: "\(StateLegend.Glyph.speaking) \(placard)")
            let voices = coordinator.voices(for: session)
            _ = await coordinator.speech.speak(
                spoken, voice: voices.cloud, systemVoice: voices.system, onWord: { _ in })
        }
    }
}

// MARK: - Manager mode: the child, its events, and the orb

extension AppDelegate {

    var managerIsOn: Bool { managerTransport != nil }

    @objc func toggleManagerMode() {
        if managerIsOn { stopManager() } else { startManager() }
        rebuildMenu()
    }

    @MainActor
    func startManager() {
        let argv = ManagerConfig.command()
        let cwd = (argv[0] as NSString).deletingLastPathComponent
        let transport = ACPProcessTransport(command: argv, cwd: cwd,
                                            environment: ManagerConfig.environment())
        do { try transport.start() } catch {
            hud.showResult("Manager could not start: \(error.localizedDescription)")
            Permissions.log("manager: start failed \(error)")
            return
        }
        managerTransport = transport
        hud.setManager(on: true)
        Permissions.log("manager: started \(argv.joined(separator: " "))")
        managerTask = Task { @MainActor [weak self] in
            for await line in transport.lines() {
                guard let self, let event = ManagerEvent.parse(line) else { continue }
                self.handle(event)
            }
            // The child ended, by us or by itself. Either way the lamp goes out.
            self?.hud.setManager(on: false)
            self?.managerTransport = nil
            Permissions.log("manager: child ended")
            self?.rebuildMenu()
        }
    }

    @MainActor
    func stopManager() {
        managerTask?.cancel()
        managerTask = nil
        if let transport = managerTransport { Task { await transport.close() } }
        managerTransport = nil
        hud.setManager(on: false)
        Permissions.log("manager: stopped")
    }

    @MainActor
    private func handle(_ e: ManagerEvent) {
        let p = String(format: "%.2f", e.p ?? 0)
        Permissions.log("manager event: \(e.event.rawValue) p=\(p) intent=\(e.intent ?? "-") \(e.text?.prefix(60) ?? e.reason?.prefix(60) ?? "")")
        // The line under the orb is for the person, in words; the numbers live
        // in the event stream (tb-voice/server/tail.py) and in this log.
        switch e.event {
        // The thinking orb (composing) is the resting face. Hearing you lights
        // the gradient; addressed switches to solving; speaking weaves.
        case .hearing:
            hud.setManagerState(StatusHUD.orbState, line: "hearing you", mood: "hearing")
        case .listening:
            hud.setManagerState(StatusHUD.orbState, line: "listening")
        case .addressed:
            hud.setManagerState(StatusHUD.orbState, line: Self.intentLine(e.intent))
        case .speaking:
            hud.setManagerState(StatusHUD.orbState, line: e.voice == "agent" ? "the agent is speaking" : "speaking", mood: "speaking")
        case .stage:
            hud.setManagerState(StatusHUD.orbState, line: "on stage: \(e.goal ?? e.project ?? "")")
        case .earcon:
            if let name = e.name, let cue = EarconGate.Cue(rawValue: name) { Earcons.acknowledge(cue) }
        case .tool:
            hud.setManagerState(StatusHUD.orbState, line: e.meaning.map { "sent: \($0)" } ?? "working")
        case .error:
            hud.setManagerState(StatusHUD.orbState, line: "something failed; check the log")
        }
    }

    /// What the manager is doing about what you said, in words.
    static func intentLine(_ intent: String?) -> String {
        switch intent ?? "" {
        case "invite_next": return "inviting the next agent"
        case "rung_goal": return "reading the goal"
        case "rung_findings": return "reading the findings"
        case "rung_solution": return "reading the next step"
        case "rung_why": return "reading the reasoning"
        case "custom": return "answering"
        case "send_message": return "sending"
        case "start_agent": return "starting an agent"
        case "summarize_recent": return "summarising recent work"
        case "teach": return "explaining"
        case "speak": return "here"
        case let s where s.hasPrefix("confirm:"): return "confirming"
        default: return "heard you"
        }
    }
}
