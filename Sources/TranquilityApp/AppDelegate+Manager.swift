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
        let orb = managerOrb ?? ManagerOrb()
        managerOrb = orb
        orb.set(.idle, line: "Tranquility · listening")
        orb.show()
        Permissions.log("manager: started \(argv.joined(separator: " "))")
        managerTask = Task { @MainActor [weak self] in
            for await line in transport.lines() {
                guard let self, let event = ManagerEvent.parse(line) else { continue }
                self.handle(event)
            }
            // The child ended, by us or by itself. Either way the lamp goes out.
            self?.managerOrb?.set(.idle, line: "Tranquility · off")
            self?.managerOrb?.hide()
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
        managerOrb?.hide()
        Permissions.log("manager: stopped")
    }

    @MainActor
    private func handle(_ e: ManagerEvent) {
        guard let orb = managerOrb else { return }
        switch e.event {
        case .listening:
            orb.set(.heard, line: "heard · \(String(format: "%.2f", e.p ?? 0))")
        case .addressed:
            orb.set(.addressed, line: "\(e.intent ?? "addressed") · \(String(format: "%.2f", e.p ?? 0))")
        case .speaking:
            orb.set(.speaking, line: e.voice == "agent" ? "the session speaks" : "Tranquility speaks")
        case .stage:
            orb.set(.stage, line: "on stage: \(e.goal ?? e.project ?? e.session?.prefix(8).description ?? "")")
        case .earcon:
            if let name = e.name, let cue = EarconGate.Cue(rawValue: name) { Earcons.acknowledge(cue) }
        case .tool:
            orb.set(.addressed, line: "→ \(e.meaning ?? (e.text ?? "tool"))")
        }
    }
}
