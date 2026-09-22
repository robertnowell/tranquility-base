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
                // The words themselves go under the orb, and stay there after the
                // voice stops: what was said is what you want to read.
                hud.setManagerState(StatusHUD.orbState, line: spoken.text, mood: "speaking")
                let voices = coordinator.voices(for: session)
                _ = await coordinator.speech.speak(
                    spoken, voice: voices.cloud, systemVoice: voices.system, onWord: { _ in })
                hud.setManagerState(StatusHUD.orbState, line: spoken.text)
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

    var managerIsOn: Bool { managerTransport != nil || managerSocket != nil }

    @objc func toggleManagerMode() {
        if managerIsOn { stopManager() } else { startManager() }
        rebuildMenu()
    }

    @MainActor
    func startManager() {
        // A hosted manager when configured and no local command is: the same
        // event lines arrive over a socket instead of a pipe, and the bot asks
        // this process for its doors (ManagerSocket.swift).
        if ManagerConfig.explicitCommand() == nil, let hosted = ManagerSessionStarter.hosted() {
            startHostedManager(hosted)
            return
        }
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
        hud.setManager(on: true)  // breathing, "connecting", until the child says ready
        Permissions.log("manager: started \(argv.joined(separator: " "))")
        managerTask = Task { @MainActor [weak self] in
            for await line in transport.lines() {
                guard let self, let event = ManagerEvent.parse(line) else { continue }
                self.handle(event)
            }
            guard let self else { return }
            let status = transport.exitStatus
            Permissions.log("manager: child ended (exit \(status.map(String.init) ?? "?"))")
            // 75 is the child's own "reload me": its source changed under it.
            // Restart in place; the orb never drops. Anything else is the end.
            if status == 75, self.managerTransport === transport {
                self.managerTransport = nil
                self.hud.setManagerState(StatusHUD.orbState, line: "reloading")
                try? await Task.sleep(nanoseconds: 300_000_000)
                self.startManager()
                return
            }
            self.hud.setManager(on: false)
            self.managerTransport = nil
            self.rebuildMenu()
        }
    }

    @MainActor
    func stopManager() {
        managerTask?.cancel()
        managerTask = nil
        if let transport = managerTransport { Task { await transport.close() } }
        managerTransport = nil
        if let socket = managerSocket { Task { await socket.close() } }
        managerSocket = nil
        managerReconnects = 0
        managerEndedByIdle = false
        hud.setManager(on: false)
        Permissions.log("manager: stopped")
    }

    /// Cloud caps a session at four hours. A little before that, at a quiet
    /// moment, the app closes the socket itself and the reconnect path opens
    /// a fresh session; you hear nothing.
    nonisolated static let hostedSessionLife: TimeInterval = 3 * 3600 + 55 * 60

    @MainActor
    private func startHostedManager(_ hosted: ManagerSessionStarter.Hosted) {
        hud.setManager(on: true)  // breathing until the bot says ready
        managerEndedByIdle = false
        Permissions.log("manager: hosted, starting a session at \(hosted.start.host ?? "?")")
        managerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // The fleet's names go with the start so the transcriber can spell
            // them; a read at the bot's end would wait on a pipeline that does
            // not exist yet (5 s, every start, 22 Sep).
            let names = await Self.fleetNames()
            let started = Date()
            let session: ManagerSession
            do { session = try await ManagerSessionStarter.start(hosted, keyterms: names) } catch {
                self.hud.showResult("Hands-free could not start a session: \(error.localizedDescription)")
                Permissions.log("manager: hosted start failed \(error)")
                self.hud.setManager(on: false)
                return
            }
            let socket = ManagerSocket(session: session, audio: ManagerMicrophone()) { argv in
                await AppDelegate.answerManagerRequest(argv)
            }
            do { try socket.start() } catch {
                self.hud.showResult("Hands-free could not open the microphone: \(error.localizedDescription)")
                Permissions.log("manager: hosted mic failed \(error)")
                self.hud.setManager(on: false)
                return
            }
            self.managerSocket = socket
            socket.onTrace = { line in Permissions.log("manager wire: \(line)") }
            socket.onLevel = { [weak socket] level, bytes in
                Permissions.log(String(format: "manager mic: rms %.4f, %d bytes sent", level, bytes))
                // Past the session's life and the room is quiet: rotate now.
                // The mic stops with the socket, so this fires once.
                if level < 0.01, Date().timeIntervalSince(started) > Self.hostedSessionLife, let socket {
                    Permissions.log("manager: session life reached at a quiet moment; rotating")
                    Task { await socket.close() }
                }
            }
            Permissions.log("manager: hosted session \(session.sessionId ?? "?") (start \(Int(Date().timeIntervalSince(started) * 1000)) ms)")
            // Hosted, the bot keeps nothing on disk; the app keeps the stream
            // here so the viewer (tb-voice/server/tail.py) can read it.
            let eventsFile = QueueStore.supportDirectory.appendingPathComponent("manager-events.jsonl")
            let eventsHandle: FileHandle? = {
                if !FileManager.default.fileExists(atPath: eventsFile.path) {
                    FileManager.default.createFile(atPath: eventsFile.path, contents: nil)
                }
                let h = try? FileHandle(forWritingTo: eventsFile); h?.seekToEndOfFile(); return h
            }()
            defer { try? eventsHandle?.close() }
            for await line in socket.lines() {
                eventsHandle?.write(line + Data([0x0A]))
                guard let event = ManagerEvent.parse(line) else { continue }
                if event.event == .ready {
                    Permissions.log("manager: ready \(Int(Date().timeIntervalSince(started) * 1000)) ms after start")
                }
                self.handle(event)
            }
            guard self.managerSocket === socket else { return }  // stopped by the chord
            Permissions.log("manager: hosted socket ended (\(socket.closeReason ?? "closed"))")
            self.managerSocket = nil
            if self.managerEndedByIdle {
                // The bot ended it on purpose and the orb already says so; a
                // chord starts a fresh session. Reconnecting would just bill.
                self.managerEndedByIdle = false
                self.hud.setManager(on: false)
                self.rebuildMenu()
                return
            }
            // Anything else (the network, the 4 h cap, the rotation above) is
            // a fresh session with backoff: 1, 2, 4 s, then give up and say so.
            self.managerReconnects += 1
            guard self.managerReconnects <= 3 else {
                Permissions.log("manager: hosted reconnect gave up after 3 tries")
                self.hud.showResult("Hands-free lost its connection three times; press the chord to try again.")
                self.managerReconnects = 0
                self.hud.setManager(on: false)
                self.rebuildMenu()
                return
            }
            let wait = UInt64(1 << (self.managerReconnects - 1)) * 1_000_000_000
            self.hud.setManagerState(StatusHUD.orbState, line: "reconnecting")
            Permissions.log("manager: hosted reconnect \(self.managerReconnects) in \(wait / 1_000_000_000) s")
            try? await Task.sleep(nanoseconds: wait)
            guard self.managerSocket == nil, self.managerTask != nil else { return }  // stopped meanwhile
            self.startHostedManager(hosted)
        }
    }

    /// The grid's display names, for the transcriber's key terms.
    static func fleetNames() async -> [String] {
        let (code, out) = await answerManagerRequest(["tbase", "targets", "--json"])
        guard code == 0, let data = out.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { ($0["name"] as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The bot's doors, done here. `tbase …` runs the CLI this Mac has;
    /// `open <scheme>://…` is handed to the app's own deep-link handler, so
    /// the scheme the bot wrote does not matter. Anything else is refused.
    static func answerManagerRequest(_ argv: [String]) async -> (code: Int, out: String) {
        switch argv.first {
        case "tbase":
            // The exit status is the answer (send maps 0/2/3/4/5), so this is a
            // plain Process rather than Subprocess.run, which folds status into a message.
            return await Task.detached { () -> (code: Int, out: String) in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: ManagerConfig.tbasePath())
                p.arguments = Array(argv.dropFirst())
                let pipe = Pipe()
                p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch { return (127, "\(error)") }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return (Int(p.terminationStatus), String(decoding: data, as: UTF8.self))
            }.value
        case "open":
            guard argv.count > 1, let url = URL(string: argv[1]) else { return (2, "no url") }
            await MainActor.run {
                (NSApp.delegate as? AppDelegate)?.application(NSApp, open: [url])
            }
            return (0, "")
        default:
            return (2, "refused: \(argv.first ?? "")")
        }
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
        case .ready:
            // The mic-open cue plays now, when it is true: the pipeline is up.
            Earcons.acknowledge(.listening)
            managerReconnects = 0
            hud.setManagerState(StatusHUD.orbState, line: "listening")
        case .hearing:
            hud.setManagerState(StatusHUD.orbState, line: "hearing you", mood: "hearing")
        case .listening:
            break  // silent on a turn: whatever was last said stays on the panel
        case .addressed:
            hud.setManagerState(StatusHUD.orbState, line: Self.intentLine(e.intent))
        case .speaking:
            managerLastLine = e.text ?? (e.voice == "agent" ? "the agent is speaking" : "speaking")
            hud.setManagerState(StatusHUD.orbState, line: managerLastLine, mood: "speaking")
        case .reloading:
            hud.setManagerState(StatusHUD.orbState, line: "reloading")
        case .quiet:
            // Voice over: colour back to rest, the last words stay readable.
            hud.setManagerState(StatusHUD.orbState, line: managerLastLine == "speaking" ? "listening" : managerLastLine)
        case .stage:
            hud.setManagerState(StatusHUD.orbState, line: "on stage: \(e.name ?? e.goal ?? e.project ?? "")")
        case .earcon:
            if let name = e.name, let cue = EarconGate.Cue(rawValue: name) { Earcons.acknowledge(cue) }
        case .tool:
            hud.setManagerState(StatusHUD.orbState, line: e.meaning.map { "sent: \($0)" } ?? "working")
        case .error:
            hud.setManagerState(StatusHUD.orbState, line: "something failed; check the log")
        case .idle:
            managerEndedByIdle = true
            hud.setManagerState(StatusHUD.orbState, line: "paused after \((e.secs ?? 0) / 60) quiet minutes")
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
