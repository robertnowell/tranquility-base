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

    /// Speak `spoken` as the session would, and show it on the card. The same
    /// sequence the ladder uses: stop what is playing, supersede any armed
    /// announcement, then speak with the session's voice pair.
    @MainActor
    func speakForManager(session: String, spoken: SanitizedSpokenText, placard: String) {
        guard let coordinator else { return }
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
            Permissions.log("manager: speaking \(placard) for \(session.prefix(8))")
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
        switch e.event {
        case .hearing:
            hud.setManagerState("listening", line: "hearing you")
        case .error:
            hud.setManagerState("breathing", line: "error · \(e.reason ?? "")")
        case .listening:
            hud.setManagerState("breathing", line: "heard · \(p) · silent")
        case .addressed:
            hud.setManagerState("solving", line: "\(e.intent ?? "addressed") · \(p)")
        case .speaking:
            hud.setManagerState("composing", line: e.voice == "agent" ? "the session speaks" : "Tranquility speaks")
        case .stage:
            hud.setManagerState("connecting", line: "on stage · \(e.goal ?? e.project ?? e.session?.prefix(8).description ?? "")")
        case .earcon:
            if let name = e.name, let cue = EarconGate.Cue(rawValue: name) { Earcons.acknowledge(cue) }
        case .tool:
            hud.setManagerState("working", line: "→ \(e.meaning ?? (e.text ?? "tool"))")
        }
    }
}
