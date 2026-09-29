import AppKit
import TranquilityCore

/// The app's half of the hands-free manager (19 Sep 2026).
///
/// The manager is hosted, listens all day, and acts on this Mac only through
/// the wire v1 tools the app offers. This file holds the one thing it
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
            // The card belongs here too, and it is the SAME card.
            //
            // Manager mode took the card away on 19 Sep — "voice only", the orb
            // in place of the grid and one line of text under it. That made
            // hands-free a different product from the rest of the panel: no
            // name for whoever is speaking, no Open Report, no highlight
            // following the words, none of the treatment every other
            // announcement gets. There was never a reason for the difference
            // beyond the orb needing somewhere to go, and it goes above.
            //
            // So this shows what a stop always shows, and the only thing that
            // moved is which mouth reads it aloud.
            returnToGridWork?.cancel()
            announceTask?.cancel()
            coordinator.speech.stop()
            announceTask = Task { @MainActor in
                let event = try? self.store?.latestStop(for: session)
                let live = ((ClaudeAgentsCLI().sessions() ?? [])
                    + FileSessionOwnershipStore.shared.liveNonRegistrySessions())
                    .first { $0.sessionId == session }
                self.hud.showAnnouncement(
                    spoken: spoken,
                    sessionId: session,
                    pid: live?.pid,
                    project: event.map { self.tabDisplayName(for: $0, live: live) }
                        ?? (live?.cwd as NSString?)?.lastPathComponent ?? "",
                    cwd: event?.cwd ?? live?.cwd,
                    eventId: session,
                    placard: "\(StateLegend.Glyph.speaking) \(placard)")
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

// MARK: - Manager mode: the peer, its events, and the orb

extension AppDelegate {

    var managerIsOn: Bool { managerPeer != nil || managerStarting }

    /// Tell the hands-free manager who is in focus now (hf-16, "follow", ruled
    /// 27 Sep). A shortcut acts at once, as it always has; the manager is told
    /// after, so its "it" is the agent the panel just played or replied to.
    /// Before this, ⌃⌥ moved the panel on and the manager's stage stayed where
    /// it was, and "send that to it" could mean the agent before.
    func tellManagerStage(session: String, name: String?, goal: String?, via: String) {
        guard let peer = managerPeer else { return }
        peer.send(ManagerDataChannel.stamped(
            ManagerDataChannel.stageEvent(session: session, name: name, goal: goal, via: via)))
        Permissions.log("manager: stage follows the panel (\(via)) -> \(session.prefix(8))")
    }

    @objc func toggleManagerMode() {
        // `managerStarting` is in `managerIsOn` deliberately: a start in flight
        // IS hands-free being on, as far as the person pressing the chord is
        // concerned, and the alternative is buying a second session. A press
        // during the purchase now stops it, which is what a second press has
        // always meant.
        if managerIsOn { stopManager() } else { startManager() }
        rebuildMenu()
    }

    @MainActor
    func startManager() {
        // The dev shim first when it is configured (a bot of the
        // developer's own, hosted or on localhost); otherwise the Gateway.
        if let rtc = ManagerConfig.webrtc() { startWebRTCManager(rtc); return }
        switch ManagerConfig.availability() {
        case .managed:
            // Signed in: the Gateway sells the session, starts the bot, and
            // settles by the second. No key on this Mac (VOICE.md). It answers
            // with a peer connection and its relay; the dev shim above is the
            // same transport with the session bought differently.
            if let credits = managedCredits { startWebRTCManager(.managed(credits)); return }
            hud.showResult("Hands-free could not reach your account.")
            return
        case .unset:
            // Nothing to start: not signed in, and no dev shim.
            hud.showResult("Hands-free is not set up on this Mac: sign in to use it.")
            Permissions.log("manager: not configured (not signed in, no manager.webrtc)")
            return
        }
    }

    @MainActor
    func stopManager() {
        managerTask?.cancel()
        managerTask = nil
        managerStarting = false
        if let peer = managerPeer { Task { await peer.close() } }
        managerPeer = nil
        endManagerLease()
        managerReconnects = 0
        managerEndedByIdle = false
        hud.setManager(on: false)
        // The stage belongs to a session. A name carried into the next one
        // would be a lie about who a send is going to.
        managerStageName = nil
        Permissions.log("manager: stopped")
    }

    /// What a refused start says out loud. A 402 is the credit standing the
    /// panel already shows, and a 503 is the host being down: neither is a
    /// sign-out, and neither says "error" at somebody who just pressed a key.
    static func managerStartMessage(for error: Error) -> String {
        guard case let .refused(code, _)? = error as? ManagedSummaryFailure else {
            return "Hands-free could not start a session: \(error.localizedDescription)"
        }
        switch code {
        // NOT "your balance is spent": the Gateway refuses this whenever it
        // cannot reserve the next block, and a balance of zero is only one
        // reason. On 27 Sep it said this over a balance of $4.99, because a
        // session bought 1.5 seconds earlier by a double chord press was
        // holding the reservation. Telling somebody their money is gone when
        // it is not sends them to a billing page to fix a bug in the panel.
        case "insufficient_credit":
            return "Hands-free could not reserve credit for a session. "
                + "Check the balance in Setup."
        case "service_unavailable", "not_connected": return "Hands-free is unavailable right now."
        default: return "Hands-free could not start a session (\(code))."
        }
    }

    /// The Gateway's session, while it is ours to renew and end.
    struct ManagedVoiceLease {
        let client: ManagedVoiceClient
        let id: UUID
    }

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
        // Claimed BEFORE the await, so the second press of a double press finds
        // hands-free on and stops it instead of buying another session.
        managerStarting = true
        managerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.managerStarting = false }
            let started = Date()
            let names = await Self.fleetNames()
            let signaller: ManagerPeer.Signaller
            let label: String?
            // Where this session may route audio. It comes from whoever issued
            // the session, because a relay's credentials are short-lived and
            // must not live in the binary; nothing supplied means reflection
            // only, which is a home network and nothing harder.
            var ice: [IceServer] = IceServers.stunOnly
            do {
                switch source {
                case .shim(let rtc):
                    Permissions.log("manager: webrtc, starting a session at \(rtc.start.host ?? "?")")
                    let offer = try await Self.startWebRTCSession(rtc, keyterms: names)
                    if !rtc.iceServers.isEmpty { ice = rtc.iceServers }
                    signaller = Self.directSignaller(offer: offer, bearer: rtc.key)
                    label = offer.pathComponents.dropLast(2).last
                case .managed(let credits):
                    Permissions.log("manager: managed webrtc, buying a session from the Gateway")
                    let client = try await credits.voice()
                    let id = UUID()
                    let bought = try await client.start(id: id, keyterms: names)
                    guard bought.isWebRTC else { throw ManagedSummaryFailure.invalidResponse }
                    if !bought.ice.isEmpty { ice = bought.ice }
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
                                   toolHost: Self.managerToolHost, appVersion: Self.managerAppVersion,
                                   iceServers: ice)
            peer.onTrace = { [weak self] line in
                Permissions.log("manager wire: \(line)")
                // A microphone that stops without saying so is indistinguishable
                // from a person who has stopped talking, and on 27 Sep that is
                // exactly what it looked like: two sentences cut in half, the
                // orb still reading "listening". The rebuild puts the
                // microphone back (AudioEngineRebuild); this is the half that
                // makes the panel admit it happened.
                guard line.contains("MICROPHONE DROPPED") else { return }
                Task { @MainActor in
                    self?.hud.setManagerState(StatusHUD.orbState,
                                              line: "microphone came back")
                }
            }
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
            let eventsHandle = EventsLog.open(eventsFile)
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
            throw ManagerTransportError.closed
        }
        let base = rtc.start.deletingLastPathComponent()   // .../<agent>
        return base.appendingPathComponent("sessions").appendingPathComponent(session)
            .appendingPathComponent("api").appendingPathComponent("offer")
    }

    /// The grid's display names, for the transcriber's key terms.
    static func fleetNames() async -> [String] {
        guard let (code, out) = try? await ManagerCommand.run(ManagerConfig.tbasePath(), ["targets", "--json"]),
              code == 0, let data = out.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { ($0["name"] as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Everything said in hands-free, numbered and whole, on this Mac (hf-5).
    static let managerLedger: ManagerLedger = {
        let ledger = ManagerLedger(
            directory: QueueStore.supportDirectory.appendingPathComponent("ledger", isDirectory: true))
        ledger.onUnparsed = { Permissions.log($0) }
        return ledger
    }()

    /// Wire v1's tools, one host for every session and both transports, so
    /// an idempotency key outlives a reconnect (hf-3). `send` is the panel's
    /// own Send (`sendTyped`), with the developer's whole tray riding (hf-12).
    static let managerToolHost = ManagerToolHost(
        tools: ManagerTools.standard(
            tbase: ManagerConfig.tbasePath(), ledger: managerLedger,
            sender: { agent, text in
                await MainActor.run { NSApp.delegate as? AppDelegate }?
                    .sendTyped(text, to: agent, tray: .developer, provider: "manager")
            },
            // Answered by the app, not the CLI on disk: on 23 Sep a two-day-old
            // `tbase` had never heard of `voice`, exited 1, and every agent
            // talked in the manager's voice. The app assigns voices and ships
            // with the bot's changes, so the app answers.
            voice: { agent in
                guard let coordinator = await MainActor.run(body: {
                    (NSApp.delegate as? AppDelegate)?.coordinator
                }) else { return nil }
                let voices = coordinator.voices(for: agent)
                Permissions.log("manager: \(agent.prefix(8)) speaks as \(voices.cloud ?? "—")")
                return (voices.cloud, voices.system)
            },
            // The app's own deep-link handler, so the scheme the bot wrote
            // does not matter and nothing reaches the system's URL opener.
            opener: { url in
                await MainActor.run {
                    (NSApp.delegate as? AppDelegate)?.application(NSApp, open: [url])
                }
            }),
        idempotency: ManagerIdempotency(url: QueueStore.supportDirectory.appendingPathComponent("manager-idem.json")))

    static var managerAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Paint the highlight when the word is meant to be HEARD, not when its
    /// event arrives.
    ///
    /// Reported 28 Sep: "the speaking each word highlighting doesn't work, it
    /// all flashes in at once". It did. ElevenLabs returns a whole utterance's
    /// alignment together with the audio, so Pipecat emits every progress frame
    /// in the same tick -- eight events at one timestamp on 27 Sep, while the
    /// voice carried on for another three seconds. Painting on arrival lights
    /// the entire line instantly and then waits.
    ///
    /// Each frame carries the presentation timestamp of its word (`Frame.pts`),
    /// which the bot now sends as `at`. The first one to arrive anchors the
    /// clock -- the bot's timestamps are stream-wide, so only the offsets
    /// between them mean anything here -- and every later word is painted that
    /// far after it. Drift against the actual speaker is bounded by the network
    /// delay of the first event, which is milliseconds.
    ///
    /// This is what the local synthesiser always did (`11labs: onWord upTo=2
    /// t=0.104`), and what moving the speaking to the bot took away.
    @MainActor
    func paintSpoken(upTo: Int, at: Double?) {
        guard let at else {
            hud.highlight(upTo: upTo)   // an older bot: paint on arrival, as before
            return
        }
        guard let clock = spokenClock else {
            spokenClock = (firstWordAt: at, anchoredAt: Date())
            hud.highlight(upTo: upTo)
            return
        }
        let due = clock.anchoredAt.addingTimeInterval(at - clock.firstWordAt)
        let wait = due.timeIntervalSinceNow
        // Already due, or near enough that a timer would cost more than it
        // buys: paint now. The panel repaints at 20Hz anyway.
        guard wait > 0.02 else { hud.highlight(upTo: upTo); return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, self.managerIsOn else { return }
            self.hud.highlight(upTo: upTo)
        }
    }

    /// Every orb line while hands-free is up, with whoever is on stage in front
    /// of it. One funnel, so a new event cannot quietly lose the name again.
    @MainActor
    private func orbLine(_ line: String) -> String {
        guard let stage = managerStageName, !stage.isEmpty else { return line }
        return "\(stage) · \(line)"
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
            hud.setManagerState(StatusHUD.orbState, line: orbLine("listening"))
        case .hearing:
            hud.setManagerState(StatusHUD.orbState, line: orbLine("hearing you"), mood: "hearing")
        case .listening:
            break  // silent on a turn: whatever was last said stays on the panel
        case .addressed:
            hud.setManagerState(StatusHUD.orbState, line: orbLine(Self.intentLine(e.intent)))
        case .speaking:
            // The orb says WHAT is happening; the card says what was said. It
            // used to carry the whole spoken line, because there was no card in
            // manager mode to carry it — now there is, with the words and the
            // highlight following them, so repeating the sentence under the orb
            // would be the same text twice on one small panel.
            managerLastLine = e.voice == "agent" ? "the agent is speaking" : "speaking"
            hud.setManagerState(StatusHUD.orbState, line: orbLine(managerLastLine), mood: "speaking")
            // ...and the manager's own words go on the card, the same card an
            // agent's line gets. PR 638 gave the card back but only for an
            // agent, whose line arrives by URL (`speakForManager`); the
            // manager's own sentences arrive only as this event, so the panel
            // said "speaking" and never showed the sentence. Robert, 26 Sep:
            // "the text highlighter should just be there anytime it's going to
            // speak" — so it is driven by the speaking event, not by who is
            // speaking.
            //
            // An agent's line is skipped here on purpose, and not because it
            // needs no card: it needs a RICHER one. `speakForManager` has the
            // session, its project, and its doors, and it is already opening
            // that card from the `hear` URL a breath earlier. Painting a
            // doorless one here would take the stage first and lose them.
            // A new line, so the word clock starts again. Without this the
            // second utterance schedules against the first one's anchor and
            // paints its whole line at once.
            spokenClock = nil
            if e.voice != "agent", let text = e.text, !text.isEmpty {
                hud.showManagerLine(text)
            }
        case .quiet:
            // Voice over: colour back to rest, the last words stay readable.
            hud.setManagerState(StatusHUD.orbState, line: orbLine(managerLastLine == "speaking" ? "listening" : managerLastLine))
        case .stage:
            managerStageName = e.name ?? e.goal ?? e.project
            hud.setManagerState(StatusHUD.orbState, line: orbLine("on stage"))
        case .earcon:
            if let name = e.name, let cue = EarconGate.Cue(rawValue: name) { Earcons.acknowledge(cue) }
        case .tool:
            hud.setManagerState(StatusHUD.orbState, line: orbLine(e.meaning.map { "sent: \($0)" } ?? "working"))
        case .error:
            hud.setManagerState(StatusHUD.orbState, line: orbLine("something failed; check the log"))
        case .idle:
            managerEndedByIdle = true
            hud.setManagerState(StatusHUD.orbState, line: "paused after \((e.secs ?? 0) / 60) quiet minutes")
        case .spoke:
            // The same highlight the card has always used, told from the other
            // end of the connection. The card is showing the line already; this
            // only says how much of it has been heard.
            if let upTo = e.upTo { paintSpoken(upTo: upTo, at: e.at) }
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
