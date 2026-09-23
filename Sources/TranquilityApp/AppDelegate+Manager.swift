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
            // Hands-free has ONE mouth, and it is not this one.
            //
            // This used to read the line aloud here, in the session's own
            // voice, through the app's own speakers. Nothing could cancel it: a
            // canceller removes the audio its own renderer played, and this is
            // a different renderer, so the microphone heard every announcement
            // the way it hears a person. On 23 Sep the manager transcribed
            // three of them back, verbatim, as the developer's own words, and
            // acted on them.
            //
            // So the bot speaks it, down the connection, in this session's
            // ElevenLabs voice (`tbase voice <session>` is where it gets the
            // id, the same assignment this Mac has always used). It arrives
            // already cancelled, the microphone stays open through it, and you
            // can talk over an announcement — which was never possible before.
            //
            // The card and the words under the orb still belong here. Only the
            // sound moved.
            returnToGridWork?.cancel()
            announceTask?.cancel()
            coordinator.speech.stop()
            hud.setManagerState(StatusHUD.orbState, line: spoken.text, mood: "speaking")
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

    var managerIsOn: Bool { managerTransport != nil || managerSocket != nil || managerPeer != nil }

    @objc func toggleManagerMode() {
        if managerIsOn { stopManager() } else { startManager() }
        rebuildMenu()
    }

    @MainActor
    func startManager() {
        // A hosted manager when configured and no local command is: the same
        // event lines arrive over a socket instead of a pipe, and the bot asks
        // this process for its doors (ManagerSocket.swift).
        // WebRTC first when it is configured, whatever else is: it is the
        // only path where talking over the manager reaches it.
        if let rtc = ManagerConfig.webrtc() { startWebRTCManager(rtc); return }
        switch ManagerConfig.availability() {
        case .managed:
            // Signed in: the Gateway sells the session, starts the bot, and
            // settles by the second. No key on this Mac (VOICE.md).
            if let credits = managedCredits { startHostedManager(.managed(credits)); return }
            if let hosted = ManagerSessionStarter.hosted() { startHostedManager(.hosted(hosted)); return }
            hud.showResult("Hands-free could not reach your account.")
            return
        case .hosted:
            if let hosted = ManagerSessionStarter.hosted() { startHostedManager(.hosted(hosted)) }
            return
        case .unset:
            // Nothing to start. The managed path (a session issued by the
            // Gateway to a signed-in account) fills this slot when it lands.
            hud.showResult("Hands-free is not set up on this Mac: no manager is configured.")
            Permissions.log("manager: not configured (no manager.hosted, no manager.command, no local checkout)")
            return
        case .local:
            break
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
        if let peer = managerPeer { Task { await peer.close() } }
        managerPeer = nil
        endManagerLease()
        managerReconnects = 0
        managerEndedByIdle = false
        hud.setManager(on: false)
        Permissions.log("manager: stopped")
    }

    /// Where a hosted session comes from: bought from the Gateway for a
    /// signed-in account, or started directly with the dev shim's key.
    enum ManagerSource {
        case managed(ManagedCreditSession)
        case hosted(ManagerSessionStarter.Hosted)
    }

    /// The Gateway's session, while it is ours to renew and end.
    struct ManagedVoiceLease {
        let client: ManagedVoiceClient
        let id: UUID
    }

    @MainActor
    private func startHostedManager(_ source: ManagerSource) {
        hud.setManager(on: true)  // breathing until the bot says ready
        managerEndedByIdle = false
        managerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // The fleet's names go with the start so the transcriber can spell
            // them; a read at the bot's end would wait on a pipeline that does
            // not exist yet (5 s, every start, 22 Sep).
            let names = await Self.fleetNames()
            let started = Date()
            let session: ManagerSession
            var lease: ManagedVoiceLease?
            do {
                switch source {
                case .managed(let credits):
                    Permissions.log("manager: managed, buying a session from the Gateway")
                    let client = try await credits.voice()
                    let id = UUID()
                    let bought = try await client.start(id: id, keyterms: names)
                    // The Gateway decides what carries the audio, and only its
                    // answer says which. A peer connection is a different
                    // client entirely, so hand the session we have just paid
                    // for to that one rather than buying a second.
                    if bought.isWebRTC {
                        self.startWebRTCManager(.bought(ManagedVoiceLease(client: client, id: id),
                                                        renewBy: bought.renewByDate))
                        return
                    }
                    guard let url = bought.wsUrl.flatMap(URL.init(string:)) else {
                        throw ManagedSummaryFailure.invalidResponse
                    }
                    session = ManagerSession(url: url, token: bought.token, sessionId: id.uuidString.lowercased())
                    lease = ManagedVoiceLease(client: client, id: id)
                    self.managerLease = lease
                    self.scheduleManagerRenewal(lease!, renewBy: bought.renewByDate)
                case .hosted(let hosted):
                    Permissions.log("manager: hosted, starting a session at \(hosted.start.host ?? "?")")
                    session = try await ManagerSessionStarter.start(hosted, keyterms: names)
                }
            } catch {
                self.hud.showResult(Self.managerStartMessage(for: error))
                Permissions.log("manager: hosted start failed \(error)")
                self.hud.setManager(on: false)
                return
            }
            // The WebSocket path has no echo cancellation, and cannot: the
            // bot's gate is its only defence, which is why nothing said over
            // the manager reaches it here. That is what `manager.webrtc` is
            // for, and what this path is being retired in favour of.
            let socket = ManagerSocket(session: session, audio: ManagerMicrophone(), player: PCMPlayer(),
                                       toolHost: Self.managerToolHost, appVersion: Self.managerAppVersion) { argv in
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
            socket.onLevel = { level, bytes in
                Permissions.log(String(format: "manager mic: rms %.4f, %d bytes sent", level, bytes))
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
                Self.managerLedger.enqueue(line: line, session: session.sessionId)
                guard let event = ManagerEvent.parse(line) else { continue }
                if event.event == .ready {
                    Permissions.log("manager: ready \(Int(Date().timeIntervalSince(started) * 1000)) ms after start")
                }
                self.handle(event)
            }
            guard self.managerSocket === socket else { return }  // stopped by the chord
            Permissions.log("manager: hosted socket ended (\(socket.closeReason ?? "closed"))")
            self.managerSocket = nil
            // The socket is the session's life: end it so the Gateway settles
            // by the seconds we actually used rather than the block we held.
            self.endManagerLease()
            if self.managerEndedByIdle {
                // The bot ended it on purpose and the orb already says so; a
                // chord starts a fresh session. Reconnecting would just bill.
                self.managerEndedByIdle = false
                self.hud.setManager(on: false)
                self.rebuildMenu()
                return
            }
            // Anything else (the network, the 4 h cap, the bot's own rotation
            // before it) is a fresh session with backoff: 1, 2, 4 s, then give
            // up and say so.
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
            self.startHostedManager(source)
        }
    }

    /// What a refused start says out loud. A 402 is the credit standing the
    /// panel already shows, and a 503 is the host being down: neither is a
    /// sign-out, and neither says "error" at somebody who just pressed a key.
    static func managerStartMessage(for error: Error) -> String {
        guard case let .refused(code, _)? = error as? ManagedSummaryFailure else {
            return "Hands-free could not start a session: \(error.localizedDescription)"
        }
        switch code {
        case "insufficient_credit": return "Hands-free needs credit: your balance is spent."
        case "service_unavailable", "not_connected": return "Hands-free is unavailable right now."
        default: return "Hands-free could not start a session (\(code))."
        }
    }

    /// Renew a few minutes before the block runs out. A renewal opens the next
    /// window where this one ends, so an early one costs nothing; a missed one
    /// ends the session, which the socket then reports as any other drop.
    @MainActor
    private func scheduleManagerRenewal(_ lease: ManagedVoiceLease, renewBy: Date?) {
        managerRenewal?.cancel()
        guard let renewBy else { return }
        managerRenewal = Task { @MainActor [weak self] in
            var next = renewBy
            while !Task.isCancelled {
                let wait = max(30, next.timeIntervalSinceNow - 180)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled, let self, self.managerLease?.id == lease.id else { return }
                do {
                    let renewed = try await lease.client.renew(id: lease.id)
                    guard let by = renewed.renewByDate else { return }
                    Permissions.log("manager: renewed, block \(renewed.blocks), next by \(by)")
                    next = by
                } catch {
                    Permissions.log("manager: renewal failed \(error)")
                    return  // the socket's end is the thing that reconnects
                }
            }
        }
    }

    /// End the Gateway session, once. Settling twice changes nothing, but the
    /// call is not free, so the lease is cleared before it is made.
    @MainActor
    func endManagerLease() {
        guard let lease = managerLease else { return }
        managerLease = nil
        managerRenewal?.cancel()
        managerRenewal = nil
        Task {
            do {
                let ended = try await lease.client.end(id: lease.id)
                Permissions.log("manager: session ended, charged \(ended.chargedSeconds ?? "?") s")
            } catch {
                Permissions.log("manager: end failed \(error)")
            }
        }
    }

    /// Hands-free over WebRTC: one session, one peer connection, and the
    /// engine cancelling the manager's own voice out of the microphone so it
    /// can be interrupted. The panel sees the same lines it always has.
    @MainActor
    /// The dev shim's road: straight at the host, with a key of its own.
    static func directSignaller(offer: URL, bearer: String?) -> ManagerPeer.Signaller {
        { method, body in
            var request = URLRequest(url: offer)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else { throw ManagedSummaryFailure.refused(code: "http_\(status)", operationId: nil) }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
    }

    /// The paid road: through the Gateway, which carries the message because
    /// this Mac holds no vendor key and the host's endpoint refuses anything
    /// without one.
    static func managedSignaller(_ client: ManagedVoiceClient, id: UUID) -> ManagerPeer.Signaller {
        { method, body in try await client.signal(id: id, method: method, body: body) }
    }

    /// Where a WebRTC session comes from. The shim starts one directly with a
    /// key of its own; the managed path buys one from the Gateway, which
    /// carries the signalling afterwards because this Mac holds no vendor key.
    enum WebRTCSource {
        case shim(ManagerConfig.WebRTCManager)
        case managed(ManagedCreditSession)
        /// Already bought, because the transport is only known once the
        /// Gateway has answered: the socket path starts the purchase and hands
        /// the session over here rather than paying for a second one.
        case bought(ManagedVoiceLease, renewBy: Date?)
    }

    private func startWebRTCManager(_ rtc: ManagerConfig.WebRTCManager) { startWebRTCManager(.shim(rtc)) }

    private func startWebRTCManager(_ source: WebRTCSource) {
        hud.setManager(on: true)
        managerEndedByIdle = false
        managerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let started = Date()
            let names = await Self.fleetNames()
            let signaller: ManagerPeer.Signaller
            let label: String?
            do {
                switch source {
                case .shim(let rtc):
                    Permissions.log("manager: webrtc, starting a session at \(rtc.start.host ?? "?")")
                    let offer = try await Self.startWebRTCSession(rtc, keyterms: names)
                    signaller = Self.directSignaller(offer: offer, bearer: rtc.key)
                    label = offer.pathComponents.dropLast(2).last
                case .managed(let credits):
                    Permissions.log("manager: managed webrtc, buying a session from the Gateway")
                    let client = try await credits.voice()
                    let id = UUID()
                    let bought = try await client.start(id: id, keyterms: names)
                    guard bought.isWebRTC else { throw ManagedSummaryFailure.invalidResponse }
                    let lease = ManagedVoiceLease(client: client, id: id)
                    self.managerLease = lease
                    self.scheduleManagerRenewal(lease, renewBy: bought.renewByDate)
                    signaller = Self.managedSignaller(client, id: id)
                    label = id.uuidString.lowercased()
                case .bought(let lease, let renewBy):
                    Permissions.log("manager: managed webrtc session \(lease.id.uuidString.lowercased())")
                    self.managerLease = lease
                    self.scheduleManagerRenewal(lease, renewBy: renewBy)
                    signaller = Self.managedSignaller(lease.client, id: lease.id)
                    label = lease.id.uuidString.lowercased()
                }
            } catch {
                self.hud.showResult(Self.managerStartMessage(for: error))
                Permissions.log("manager: webrtc start failed \(error)")
                self.hud.setManager(on: false)
                return
            }
            let peer = ManagerPeer(signal: signaller,
                                   toolHost: Self.managerToolHost, appVersion: Self.managerAppVersion) { argv in
                await AppDelegate.answerManagerRequest(argv)
            }
            peer.onTrace = { line in Permissions.log("manager wire: \(line)") }
            do { try peer.start() } catch {
                self.hud.showResult("Hands-free could not open the microphone: \(error.localizedDescription)")
                Permissions.log("manager: webrtc peer failed \(error)")
                self.hud.setManager(on: false)
                return
            }
            self.managerPeer = peer
            // The device the app chose, not the system default. The module
            // lists nothing until audio is running, so this waits for it.
            let wanted = AudioInputDevice.resolve()?.name
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard self.managerPeer === peer, let wanted else { return }
                let landed = peer.pinMicrophone(named: wanted)
                Permissions.log("manager: microphone \(landed)\(landed == wanted ? "" : " (wanted \(wanted))"), "
                                + "echo cancellation \(peer.echoCancellationIsActive ? "on" : "OFF")")
                Permissions.log("manager audio: \(peer.audioPathDescription)")
            }
            let eventsFile = QueueStore.supportDirectory.appendingPathComponent("manager-events.jsonl")
            let eventsHandle: FileHandle? = {
                if !FileManager.default.fileExists(atPath: eventsFile.path) {
                    FileManager.default.createFile(atPath: eventsFile.path, contents: nil)
                }
                let h = try? FileHandle(forWritingTo: eventsFile); h?.seekToEndOfFile(); return h
            }()
            defer { try? eventsHandle?.close() }
            for await line in peer.lines() {
                eventsHandle?.write(line + Data([0x0A]))
                Self.managerLedger.enqueue(line: line, session: label)
                guard let event = ManagerEvent.parse(line) else { continue }
                if event.event == .ready {
                    Permissions.log("manager: ready \(Int(Date().timeIntervalSince(started) * 1000)) ms after start")
                }
                self.handle(event)
            }
            guard self.managerPeer === peer else { return }  // stopped by the chord
            Permissions.log("manager: webrtc session ended")
            self.managerPeer = nil
            if self.managerEndedByIdle {
                self.managerEndedByIdle = false
                self.hud.setManager(on: false)
                self.rebuildMenu()
                return
            }
            self.managerReconnects += 1
            // Five, not three: a session can land on an instance that is being
            // replaced, and on 23 Sep two in a row did. Each costs five
            // seconds now rather than fifteen, so trying more is cheap and
            // giving up early is what the person actually feels.
            guard self.managerReconnects <= 5 else {
                Permissions.log("manager: webrtc reconnect gave up after 5 tries")
                self.hud.showResult("Hands-free lost its connection three times; press the chord to try again.")
                self.managerReconnects = 0
                self.hud.setManager(on: false)
                self.rebuildMenu()
                return
            }
            let wait = UInt64(1 << (self.managerReconnects - 1)) * 1_000_000_000
            self.hud.setManagerState(StatusHUD.orbState, line: "reconnecting")
            try? await Task.sleep(nanoseconds: wait)
            guard self.managerPeer == nil, self.managerTask != nil else { return }
            self.startWebRTCManager(source)
        }
    }

    /// `POST /start` on the hosted agent, then the session's own offer route.
    /// Pipecat Cloud starts the session before any offer exists, so the bot is
    /// waiting by the time this returns.
    static func startWebRTCSession(_ rtc: ManagerConfig.WebRTCManager, keyterms: [String]) async throws -> URL {
        var request = URLRequest(url: rtc.start)
        request.httpMethod = "POST"
        request.setValue("Bearer \(rtc.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["createDailyRoom": false])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = obj["sessionId"] as? String else {
            throw ManagerSocketError.closed
        }
        let base = rtc.start.deletingLastPathComponent()   // .../<agent>
        return base.appendingPathComponent("sessions").appendingPathComponent(session)
            .appendingPathComponent("api").appendingPathComponent("offer")
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
    /// Wire v1's tools, one host for every session and both transports, so
    /// an idempotency key outlives a reconnect (hf-3). Reads today; effects
    /// still go through `answerManagerRequest` until send moves to Coordinator.
    /// Everything said in hands-free, numbered and whole, on this Mac (hf-5).
    static let managerLedger: ManagerLedger = {
        let ledger = ManagerLedger(
            directory: QueueStore.supportDirectory.appendingPathComponent("ledger", isDirectory: true))
        ledger.onUnparsed = { Permissions.log($0) }
        return ledger
    }()

    static let managerToolHost = ManagerToolHost(
        tools: ManagerTools.standard(tbase: ManagerConfig.tbasePath(), ledger: managerLedger),
        idempotency: ManagerIdempotency(url: QueueStore.supportDirectory.appendingPathComponent("manager-idem.json")))

    static var managerAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

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
        case .said:
            break  // the ledger has it (managerLedger); nothing to paint
        case .rotate:
            // The bot is ending the session before Cloud's cap, at a moment
            // with nothing open; the socket's end reconnects. Say nothing.
            break
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
